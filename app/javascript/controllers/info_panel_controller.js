import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["backdrop", "button", "panel"]

  connect() {
    this.close()
  }

  toggle() {
    if (this.open) {
      this.close()
    } else {
      this.show()
    }
  }

  show() {
    this.open = true
    this.panelTarget.classList.remove("translate-x-full")
    this.panelTarget.classList.add("translate-x-0")
    this.backdropTarget.classList.remove("hidden")
    this.buttonTarget.setAttribute("aria-expanded", "true")
  }

  close() {
    this.open = false
    this.panelTarget.classList.add("translate-x-full")
    this.panelTarget.classList.remove("translate-x-0")
    this.backdropTarget.classList.add("hidden")
    this.buttonTarget.setAttribute("aria-expanded", "false")
  }
}
