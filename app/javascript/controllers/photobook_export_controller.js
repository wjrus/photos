import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["status", "download", "order"]
  static values = { url: String, status: String }

  connect() {
    this.disconnected = false
    if (["pending", "processing"].includes(this.statusValue)) this.pollTimer = setTimeout(() => this.poll(), 1500)
  }

  disconnect() {
    this.disconnected = true
    clearTimeout(this.pollTimer)
    this.request?.abort()
  }

  async poll() {
    this.request = new AbortController()
    try {
      const response = await fetch(this.urlValue, { headers: { "Accept": "application/json" }, signal: this.request.signal })
      if (!response.ok) throw new Error("Export status unavailable")
      const result = await response.json()
      this.statusTarget.textContent = result.status === "failed" ? result.error : result.status === "ready" ? "Ready" : `${result.status === "pending" ? "Queued" : "Preparing"} · ${result.processed_pages}/${result.total_pages} pages`
      if (result.file_url) {
        this.downloadTarget.href = result.file_url
        this.downloadTarget.hidden = false
      }
      if (result.order_url && this.hasOrderTarget) {
        this.orderTarget.href = result.order_url
        this.orderTarget.hidden = false
      }
      if (["pending", "processing"].includes(result.status) && !this.disconnected) this.pollTimer = setTimeout(() => this.poll(), 2000)
    } catch (error) {
      if (error.name !== "AbortError") this.statusTarget.textContent = "Status could not load. Reload this page to check your PDF."
    }
  }
}
