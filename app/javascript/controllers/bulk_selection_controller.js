import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["action", "count"]
  static values = {
    formId: String
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
      target.textContent = count === 0 ? "Select items, then choose an action." : `${count} selected`
    })
  }

  guard(event) {
    if (this.selectedInputs().length > 0) return

    event.preventDefault()
    event.stopPropagation()
  }

  selectedInputs() {
    return Array.from(document.querySelectorAll(`input[form="${CSS.escape(this.formIdValue)}"]:checked`))
  }
}
