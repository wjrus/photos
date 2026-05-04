import { Controller } from "@hotwired/stimulus"
import { appendNextStreamPage } from "controllers/stream_page_loader"

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
    if (this.hasSentinelTarget) {
      this.observer.observe(this.sentinelTarget)
    }
  }

  async loadIfVisible(entries) {
    if (this.loadingValue || !entries.some((entry) => entry.isIntersecting)) return
    if (!this.hasSentinelTarget) return

    this.loadingValue = true

    try {
      this.observer.unobserve(this.sentinelTarget)
      await appendNextStreamPage(this.sentinelTarget)
      this.loadingValue = false
      this.observeSentinel()
    } catch (error) {
      this.sentinelTarget.textContent = error.message
      this.loadingValue = false
    }
  }
}
