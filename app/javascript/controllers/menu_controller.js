import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  connect() {
    this.closeOnOutsideClick = this.closeOnOutsideClick.bind(this)
    this.closeOnEscape = this.closeOnEscape.bind(this)
    this.syncExpanded = this.syncExpanded.bind(this)
    document.addEventListener("click", this.closeOnOutsideClick)
    document.addEventListener("keydown", this.closeOnEscape)
    this.element.addEventListener("toggle", this.syncExpanded)
    this.summaryElement?.setAttribute("aria-expanded", this.element.open ? "true" : "false")
  }

  disconnect() {
    document.removeEventListener("click", this.closeOnOutsideClick)
    document.removeEventListener("keydown", this.closeOnEscape)
    this.element.removeEventListener("toggle", this.syncExpanded)
  }

  closeOnOutsideClick(event) {
    if (!this.element.open || this.element.contains(event.target)) return

    this.element.open = false
  }

  closeOnEscape(event) {
    if (event.key !== "Escape" || !this.element.open) return

    event.preventDefault()
    event.stopPropagation()
    this.element.open = false
    this.summaryElement?.focus()
  }

  syncExpanded() {
    this.summaryElement?.setAttribute("aria-expanded", this.element.open ? "true" : "false")
  }

  get summaryElement() {
    return this.element.querySelector("summary")
  }
}
