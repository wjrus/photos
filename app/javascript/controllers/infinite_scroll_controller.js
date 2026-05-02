import { Controller } from "@hotwired/stimulus"

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

    const url = this.sentinelTarget.dataset.nextUrl
    if (!url) return

    this.loadingValue = true
    this.sentinelTarget.textContent = "Loading..."

    try {
      const response = await fetch(url, { headers: { "Accept": "text/html" } })
      if (!response.ok) throw new Error("Could not load more photos.")

      const html = await response.text()
      this.observer.unobserve(this.sentinelTarget)
      this.sentinelTarget.insertAdjacentHTML("beforebegin", html)
      this.sentinelTarget.remove()
      this.loadingValue = false
      this.observeSentinel()
    } catch (error) {
      this.sentinelTarget.textContent = error.message
      this.loadingValue = false
    }
  }
}
