import { Controller } from "@hotwired/stimulus"

const MAX_RECOVERY_ATTEMPTS = 3

// Start the next few screens of thumbnails before native lazy loading would,
// without sending an entire feed's worth of requests to the image endpoint.
export default class extends Controller {
  static targets = ["image"]

  connect() {
    this.nearby = new Set()
    this.pending = new Map()
    this.failed = new Set()
    this.recoveryAttempts = new WeakMap()
    this.schedule = this.schedule.bind(this)
    this.observe = this.observe.bind(this)
    this.recover = this.recover.bind(this)
    this.imageFailed = this.imageFailed.bind(this)
    const connection = navigator.connection
    this.constrained = connection?.saveData || /(^|-)2g$/.test(connection?.effectiveType || "")
    this.limit = this.constrained ? 2 : 6
    window.addEventListener("scroll", this.schedule, { passive: true })
    window.addEventListener("resize", this.observe)
    window.addEventListener("online", this.recover)
    window.addEventListener("focus", this.recover)
    document.addEventListener("visibilitychange", this.recover)
    this.element.addEventListener("error", this.imageFailed, true)
    this.observe()
  }

  disconnect() {
    this.observer?.disconnect()
    window.removeEventListener("scroll", this.schedule)
    window.removeEventListener("resize", this.observe)
    window.removeEventListener("online", this.recover)
    window.removeEventListener("focus", this.recover)
    document.removeEventListener("visibilitychange", this.recover)
    this.element.removeEventListener("error", this.imageFailed, true)
    clearTimeout(this.retryTimer)
    this.retryTimer = null
    cancelAnimationFrame(this.frame)
    this.pending.forEach((finish) => finish())
    cancelAnimationFrame(this.frame)
    this.frame = null
    this.nearby.clear()
    this.failed.clear()
  }

  observe() {
    this.observer?.disconnect()
    this.margin = this.constrained ? 0 : Math.min(4000, Math.max(2000, window.innerHeight * 3))
    this.observer = new IntersectionObserver((entries) => {
      entries.forEach(({ target, isIntersecting }) => {
        if (isIntersecting) this.nearby.add(target)
        else this.nearby.delete(target)
      })
      this.schedule()
    }, { rootMargin: `${this.margin}px 0px` })
    this.imageTargets.forEach((image) => this.imageTargetConnected(image))
    this.schedule()
  }

  imageTargetConnected(image) {
    // A restored Turbo page can contain images that failed before reconnecting.
    if (image.complete && !image.naturalWidth && image.getAttribute("src")) this.failed?.add(image)
    if (!image.complete || this.failed?.has(image)) this.observer?.observe(image)
  }

  imageTargetDisconnected(image) {
    this.observer?.unobserve(image)
    this.nearby?.delete(image)
    this.pending?.get(image)?.()
    this.failed?.delete(image)
    this.recoveryAttempts?.delete(image)
  }

  imageFailed(event) {
    const image = event.target
    if (!image.matches("img[data-thumbnail-preload-target~='image']") || !image.getAttribute("src")) return

    this.failed.add(image)
    this.nearby.delete(image)
    this.observer.unobserve(image)
    if (!this.retryTimer && !document.hidden && navigator.onLine !== false &&
        (this.recoveryAttempts.get(image) || 0) < MAX_RECOVERY_ATTEMPTS) {
      // Errors can arrive just after the page's resume event. Retry after a
      // short pause too, with one timer and the same per-image attempt limit.
      this.retryTimer = setTimeout(this.recover, 1000)
    }
  }

  recover() {
    clearTimeout(this.retryTimer)
    this.retryTimer = null
    if (document.hidden || navigator.onLine === false) return

    // Only revisit failed images, using the same URL and normal authorization.
    // Intersections and the existing request limit keep recovery near the viewport.
    this.failed.forEach((image) => {
      if (image.isConnected) this.observer.observe(image)
    })
    this.schedule()
  }

  schedule() {
    if (this.frame) return
    this.frame = requestAnimationFrame(() => {
      this.frame = null
      this.preload()
    })
  }

  preload() {
    if (document.hidden) return

    const candidates = []
    this.nearby.forEach((image) => {
      if (!image.isConnected || (image.complete && !this.failed.has(image)) ||
          (this.recoveryAttempts.get(image) || 0) >= MAX_RECOVERY_ATTEMPTS) {
        this.nearby.delete(image)
        this.observer.unobserve(image)
        return
      }
      const rect = image.getBoundingClientRect()
      const distance = Math.max(-rect.bottom, rect.top - window.innerHeight, 0)
      if (!distance) image.fetchPriority = "high"
      if (!this.pending.has(image) && distance <= this.margin && rect.width && rect.height) {
        candidates.push({ image, distance })
      }
    })
    candidates.sort((a, b) => a.distance - b.distance)
    for (const { image } of candidates) {
      if (this.pending.size >= this.limit) break
      this.load(image)
    }
  }

  load(image) {
    const loaded = async () => {
      try {
        // Download and decode while offscreen, so scrolling does not wait for paint.
        await image.decode()
        if (this.pending.get(image) === finish) {
          this.failed.delete(image)
          this.recoveryAttempts.delete(image)
        }
      } catch {
        // A failed image must release its slot just like a successful one.
      }
      finish()
    }
    const finish = () => {
      if (this.pending.get(image) !== finish) return
      image.removeEventListener("load", loaded)
      image.removeEventListener("error", finish)
      this.pending.delete(image)
      this.nearby.delete(image)
      this.observer.unobserve(image)
      this.schedule()
    }
    this.pending.set(image, finish)
    image.addEventListener("load", loaded)
    image.addEventListener("error", finish)
    image.loading = "eager"
    if (this.failed.delete(image)) {
      this.recoveryAttempts.set(image, (this.recoveryAttempts.get(image) || 0) + 1)
      image.src = image.getAttribute("src")
    }
    if (image.complete) loaded()
  }
}
