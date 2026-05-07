import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["button", "progress", "status", "bar", "link"]
  static values = { createUrl: String, pollUrl: String }

  connect() {
    this.pollTimer = null
  }

  disconnect() {
    this.stopPolling()
  }

  async start(event) {
    event.preventDefault()
    if (this.buttonTarget.disabled) return

    this.buttonTarget.disabled = true
    this.showProgress("Preparing ZIP...", 0)

    const response = await fetch(this.createUrlValue, {
      method: "POST",
      headers: {
        "Accept": "application/json",
        "X-CSRF-Token": document.querySelector("meta[name='csrf-token']")?.content
      }
    })

    if (!response.ok) {
      this.fail("Could not start ZIP.")
      return
    }

    this.update(await response.json())
    this.startPolling()
  }

  startPolling() {
    this.stopPolling()
    this.pollTimer = window.setInterval(() => this.poll(), 1500)
  }

  stopPolling() {
    if (!this.pollTimer) return

    window.clearInterval(this.pollTimer)
    this.pollTimer = null
  }

  async poll() {
    const response = await fetch(this.pollUrlValue, { headers: { "Accept": "application/json" } })
    if (!response.ok) {
      this.fail("Could not check ZIP progress.")
      return
    }

    this.update(await response.json())
  }

  update(download) {
    if (download.show_url) this.pollUrlValue = download.show_url

    const percent = download.progress_percent || 0
    const total = download.total_entries || 0
    const processed = download.processed_entries || 0

    if (download.status === "ready") {
      this.showProgress("ZIP ready.", 100)
      this.linkTarget.href = download.file_url
      this.linkTarget.hidden = false
      this.buttonTarget.hidden = true
      this.stopPolling()
      return
    }

    if (download.status === "failed") {
      this.fail(download.error || "ZIP failed.")
      return
    }

    const detail = total > 0 ? `${processed} of ${total} files` : "Queued"
    this.showProgress(detail, percent)
  }

  showProgress(message, percent) {
    this.progressTarget.hidden = false
    this.statusTarget.textContent = message
    this.barTarget.style.width = `${percent}%`
  }

  fail(message) {
    this.stopPolling()
    this.buttonTarget.disabled = false
    this.statusTarget.textContent = message
    this.barTarget.style.width = "0%"
  }
}
