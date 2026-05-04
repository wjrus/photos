import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["action", "bar", "count"]
  static values = {
    formId: String,
    emptyLabel: { type: String, default: "Select items, then choose an action." }
  }

  connect() {
    this.update()
  }

  update() {
    const count = this.selectedInputs().length
    const disabled = count === 0

    this.actionTargets.forEach((action) => {
      if ("disabled" in action) {
        action.disabled = disabled
      }

      action.classList.toggle("bulk-action-disabled", disabled)
      action.setAttribute("aria-disabled", disabled ? "true" : "false")
    })

    this.countTargets.forEach((target) => {
      target.textContent = count === 0 ? this.emptyLabelValue : `${count} selected`
    })

    this.barTargets.forEach((bar) => {
      bar.classList.toggle("hidden", disabled)
      bar.classList.toggle("flex", !disabled)
    })
  }

  clear(event) {
    event.preventDefault()

    this.selectedInputs().forEach((input) => {
      input.checked = false
    })

    this.update()
  }

  toggleCard(event) {
    const input = this.inputForCard(event.currentTarget)
    if (!input || this.selectedInputs().length === 0) return

    event.preventDefault()
    input.checked = !input.checked
    input.dispatchEvent(new Event("change", { bubbles: true }))
  }

  guard(event) {
    if (this.selectedInputs().length > 0) return

    event.preventDefault()
    event.stopPropagation()
  }

  selectedInputs() {
    return Array.from(document.querySelectorAll(`input[form="${CSS.escape(this.formIdValue)}"]:checked`))
  }

  inputForCard(cardLink) {
    const card = cardLink.closest("[data-bulk-selection-card]")
    return card?.querySelector(`input[form="${CSS.escape(this.formIdValue)}"]`)
  }
}
