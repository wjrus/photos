import { Controller } from "@hotwired/stimulus"
import { appendNextStreamPage, prependPreviousStreamPage } from "controllers/stream_page_loader"

export default class extends Controller {
  static targets = ["sentinel"]
  static values = {
    loading: Boolean
  }

  connect() {
    this.observer = new IntersectionObserver((entries) => this.loadIfVisible(entries), {
      rootMargin: "800px 0px"
    })
    this.observeSentinel()
  }

  disconnect() {
    this.observer?.disconnect()
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
    if (this.loadingValue || !entries.some((entry) => entry.isIntersecting)) return
    const sentinel = entries.find((entry) => entry.isIntersecting)?.target
    if (!sentinel) return

    this.loadingValue = true

    try {
      this.observer.unobserve(sentinel)
      if (sentinel.dataset.streamPageDirection === "newer") {
        await prependPreviousStreamPage(sentinel)
      } else {
        await appendNextStreamPage(sentinel)
      }
      this.loadingValue = false
      this.observeSentinel()
    } catch (error) {
      sentinel.textContent = error.message
      this.loadingValue = false
    }
  }
}
