import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["source", "status"]
  static values = { auto: Boolean }

  connect() {
    if (!this.autoValue) return

    this.autoValue = false
    requestAnimationFrame(() => this.copy())
  }

  async copy(event) {
    try {
      await navigator.clipboard.writeText(this.sourceTarget.value)
      this.statusTarget.textContent = "Link copied."
      if (!event) this.updateFlash("Share link created and copied to your clipboard.")
    } catch {
      if (event) {
        this.sourceTarget.focus()
        this.sourceTarget.select()
        this.statusTarget.textContent = "Link selected."
      } else {
        this.statusTarget.textContent = "Automatic copy was blocked."
        this.updateFlash("Share link created, but automatic copy was blocked. Use Copy link in Album info.")
      }
    }
  }

  updateFlash(message) {
    const flashMessage = document.querySelector("[data-flash-message]")
    if (flashMessage) flashMessage.textContent = message
  }
}
