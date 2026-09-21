import { Controller } from "@hotwired/stimulus"
import { appendNextStreamPage, prependPreviousStreamPage } from "controllers/stream_page_loader"

export default class extends Controller {
  static targets = ["sentinel"]

  connect() {
    this.loadingSentinels = new WeakSet()
    this.lastScrollY = window.scrollY
    this.scrollDirection = "down"
    this.updateScrollDirection = this.updateScrollDirection.bind(this)
    this.observer = new IntersectionObserver((entries) => this.loadIfVisible(entries), {
      rootMargin: "800px 0px"
    })
    window.addEventListener("scroll", this.updateScrollDirection, { passive: true })
    this.observeSentinel()
  }

  disconnect() {
    this.observer?.disconnect()
    window.removeEventListener("scroll", this.updateScrollDirection)
  }

  updateScrollDirection() {
    const scrollY = window.scrollY
    if (scrollY !== this.lastScrollY) this.scrollDirection = scrollY > this.lastScrollY ? "down" : "up"
    this.lastScrollY = scrollY
  }

  observeSentinel() {
    this.sentinelTargets.forEach((sentinel) => this.observer.observe(sentinel))
  }

  sentinelTargetConnected(sentinel) {
    this.observer?.observe(sentinel)
  }

  sentinelTargetDisconnected(sentinel) {
    this.observer?.unobserve(sentinel)
  }

  async loadIfVisible(entries) {
    const visibleSentinels = entries.filter((entry) => entry.isIntersecting).map((entry) => entry.target)
    const sentinel = this.sentinelForScrollDirection(visibleSentinels)
    if (!sentinel?.dataset.nextUrl || this.loadingSentinels.has(sentinel)) return

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
      if (!this.element.isConnected) return

      console.error(error)
      sentinel.textContent = `${error.message} Scroll to retry.`
      this.observer.observe(sentinel)
    } finally {
      this.loadingSentinels.delete(sentinel)
    }
  }

  sentinelForScrollDirection(sentinels) {
    if (sentinels.length <= 1) return sentinels[0]

    const direction = this.scrollDirection === "up" ? "newer" : "older"
    return sentinels.find((sentinel) => this.directionForSentinel(sentinel) === direction) || sentinels[0]
  }

  directionForSentinel(sentinel) {
    return sentinel.dataset.streamPageDirection === "newer" ? "newer" : "older"
  }
}
