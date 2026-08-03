import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["source", "status"]

  async copy() {
    try {
      await navigator.clipboard.writeText(this.sourceTarget.value)
      this.statusTarget.textContent = "Link copied."
    } catch {
      this.sourceTarget.focus()
      this.sourceTarget.select()
      this.statusTarget.textContent = "Link selected."
    }
  }
}
