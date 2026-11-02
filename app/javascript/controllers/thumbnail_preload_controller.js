import { Controller } from "@hotwired/stimulus"

// Start the next few screens of thumbnails before native lazy loading would,
// without sending an entire feed's worth of requests to the image endpoint.
export default class extends Controller {
  static targets = ["image"]

  connect() {
    this.nearby = new Set()
    this.pending = new Map()
    this.schedule = this.schedule.bind(this)
    this.observe = this.observe.bind(this)
    const connection = navigator.connection
    this.constrained = connection?.saveData || /(^|-)2g$/.test(connection?.effectiveType || "")
    this.limit = this.constrained ? 2 : 6
    window.addEventListener("scroll", this.schedule, { passive: true })
    window.addEventListener("resize", this.observe)
    this.observe()
  }

  disconnect() {
    this.observer?.disconnect()
    window.removeEventListener("scroll", this.schedule)
    window.removeEventListener("resize", this.observe)
    cancelAnimationFrame(this.frame)
    this.pending.forEach((finish) => finish())
    cancelAnimationFrame(this.frame)
    this.frame = null
    this.nearby.clear()
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
    if (!image.complete) this.observer?.observe(image)
  }

  imageTargetDisconnected(image) {
    this.observer?.unobserve(image)
    this.nearby?.delete(image)
    this.pending?.get(image)?.()
  }

  schedule() {
    if (this.frame) return
    this.frame = requestAnimationFrame(() => {
      this.frame = null
      this.preload()
    })
  }

  preload() {
    const candidates = []
    this.nearby.forEach((image) => {
      if (!image.isConnected || image.complete) {
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
    if (image.complete) loaded()
  }
}
