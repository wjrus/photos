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

    this.syncGroupToggles()
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

  toggleGroup(event) {
    const group = event.currentTarget.closest("[data-bulk-selection-group]")
    if (!group) return

    this.inputsForGroup(group).forEach((input) => {
      input.checked = event.currentTarget.checked
    })

    this.update()
  }

  selectedInputs() {
    return Array.from(document.querySelectorAll(`input[form="${CSS.escape(this.formIdValue)}"]:checked`))
  }

  inputForCard(cardLink) {
    const card = cardLink.closest("[data-bulk-selection-card]")
    return card?.querySelector(`input[form="${CSS.escape(this.formIdValue)}"]`)
  }

  inputsForGroup(group) {
    return Array.from(group.querySelectorAll(`input[form="${CSS.escape(this.formIdValue)}"]`))
  }

  syncGroupToggles() {
    document.querySelectorAll("[data-bulk-selection-group]").forEach((group) => {
      const toggle = group.querySelector("[data-bulk-selection-group-toggle]")
      if (!toggle) return

      const inputs = this.inputsForGroup(group)
      const selectedCount = inputs.filter((input) => input.checked).length
      toggle.checked = inputs.length > 0 && selectedCount === inputs.length
      toggle.indeterminate = selectedCount > 0 && selectedCount < inputs.length
    })
  }
}
