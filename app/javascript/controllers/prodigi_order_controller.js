import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = { url: String, version: String }

  connect() {
    this.disconnected = false
    this.timer = setTimeout(() => this.poll(), 1000)
  }

  disconnect() {
    this.disconnected = true
    clearTimeout(this.timer)
    this.request?.abort()
  }

  async poll() {
    this.request = new AbortController()
    try {
      // Reads cached database state only; this never requests the vendor API.
      if (!document.hidden) {
        const response = await fetch(this.urlValue, { headers: { Accept: "application/json" }, signal: this.request.signal })
        if (!response.ok) return
        const result = await response.json()
        if (!this.disconnected && result.version !== this.versionValue) {
          window.location.reload()
          return
        }
      }
    } catch {
      // A later poll can recover a transient connection failure.
    }
    if (!this.disconnected) this.timer = setTimeout(() => this.poll(), 5000)
  }
}
