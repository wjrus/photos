import { Controller } from "@hotwired/stimulus"
import { appendNextStreamPage, prependPreviousStreamPage } from "controllers/stream_page_loader"

export default class extends Controller {
  static targets = ["sentinel"]

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
    const sentinel = entries.find((entry) => entry.isIntersecting)?.target
    if (!sentinel || sentinel.dataset.loading === "true") return

    try {
      sentinel.dataset.loading = "true"
      this.observer.unobserve(sentinel)
      if (sentinel.dataset.streamPageDirection === "newer") {
        await prependPreviousStreamPage(sentinel)
      } else {
        await appendNextStreamPage(sentinel)
      }
      this.observeSentinel()
    } catch (error) {
      console.error(error)
      sentinel.textContent = `${error.message} Scroll to retry.`
      delete sentinel.dataset.loading
      this.observer.observe(sentinel)
    }
  }
}
