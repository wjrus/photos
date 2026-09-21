import { Controller } from "@hotwired/stimulus"
import { appendNextStreamPage, prependPreviousStreamPage } from "controllers/stream_page_loader"

export default class extends Controller {
  static targets = ["sentinel"]
  static values = { pageSize: { type: Number, default: 60 } }

  connect() {
    this.loadingSentinels = new WeakSet()
    this.retrySentinels = new Set()
    this.retryOnScroll = this.retryOnScroll.bind(this)
    this.observePages = this.observePages.bind(this)
    window.addEventListener("scroll", this.retryOnScroll, { passive: true })
    window.addEventListener("resize", this.observePages)
    this.observePages()
  }

  disconnect() {
    this.observer?.disconnect()
    window.removeEventListener("scroll", this.retryOnScroll)
    window.removeEventListener("resize", this.observePages)
    this.retrySentinels.clear()
  }

  retryOnScroll() {
    this.retrySentinels.forEach((sentinel) => {
      if (sentinel.isConnected) this.observer.observe(sentinel)
    })
    this.retrySentinels.clear()
  }

  observePages() {
    this.observer?.disconnect()
    // Keep roughly one rendered page beyond either viewport edge. Lazy images
    // let the browser prioritize nearby thumbnails without fetching the whole buffer.
    const cards = Array.from(this.element.querySelectorAll("article")).slice(0, this.pageSizeValue)
    const first = cards[0]?.getBoundingClientRect()
    const last = cards.at(-1)?.getBoundingClientRect()
    const pageHeight = first && last ? last.bottom - first.top : 0
    const margin = Math.ceil(Math.max(800, pageHeight))
    this.observer = new IntersectionObserver((entries) => this.loadIfVisible(entries), {
      rootMargin: `${margin}px 0px`
    })
    this.observeSentinel()
  }

  observeSentinel() {
    this.sentinelTargets.forEach((sentinel) => {
      if (!this.loadingSentinels.has(sentinel) && !this.retrySentinels.has(sentinel)) this.observer.observe(sentinel)
    })
  }

  sentinelTargetConnected(sentinel) {
    this.observer?.observe(sentinel)
  }

  sentinelTargetDisconnected(sentinel) {
    this.observer?.unobserve(sentinel)
    this.retrySentinels?.delete(sentinel)
  }

  loadIfVisible(entries) {
    entries.filter((entry) => entry.isIntersecting).forEach((entry) => this.loadPage(entry.target))
  }

  async loadPage(sentinel) {
    if (!sentinel?.isConnected || !sentinel.dataset.nextUrl || this.loadingSentinels.has(sentinel)) return

    try {
      this.loadingSentinels.add(sentinel)
      this.observer.unobserve(sentinel)
      if (sentinel.dataset.streamPageDirection === "newer") {
        await prependPreviousStreamPage(sentinel)
      } else {
        await appendNextStreamPage(sentinel)
      }
      if (this.element.isConnected) this.observeSentinel()
    } catch (error) {
      if (!this.element.isConnected || !sentinel.isConnected) return

      console.error(error)
      sentinel.textContent = `${error.message} Scroll to retry.`
      // Re-observing here immediately retries an intersecting sentinel in a loop.
      this.retrySentinels.add(sentinel)
    } finally {
      this.loadingSentinels.delete(sentinel)
    }
  }
}
