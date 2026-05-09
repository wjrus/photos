import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["dialog", "panel"]

  connect() {
    this.restoreFocusTo = null
    this.close()
  }

  open(event) {
    this.restoreFocusTo = event?.currentTarget || document.activeElement
    this.dialogTarget.classList.remove("hidden")
    this.dialogTarget.classList.add("flex")
    document.body.classList.add("overflow-hidden")
    this.focusFirstControl()
  }

  close() {
    this.dialogTarget.classList.add("hidden")
    this.dialogTarget.classList.remove("flex")
    document.body.classList.remove("overflow-hidden")

    if (this.restoreFocusTo?.isConnected) {
      this.restoreFocusTo.focus()
    }
  }

  backdrop(event) {
    if (!this.panelTarget.contains(event.target)) {
      this.close()
    }
  }

  keydown(event) {
    if (this.dialogTarget.classList.contains("hidden")) return

    if (event.key === "Escape") {
      event.preventDefault()
      event.stopPropagation()
      this.close()
    } else if (event.key === "Tab") {
      this.trapFocus(event)
    }
  }

  focusFirstControl() {
    const first = this.focusableElements()[0]
    first?.focus()
  }

  trapFocus(event) {
    const focusable = this.focusableElements()
    if (focusable.length === 0) {
      event.preventDefault()
      this.panelTarget.focus()
      return
    }

    const first = focusable[0]
    const last = focusable[focusable.length - 1]

    if (event.shiftKey && document.activeElement === first) {
      event.preventDefault()
      last.focus()
    } else if (!event.shiftKey && document.activeElement === last) {
      event.preventDefault()
      first.focus()
    }
  }

  focusableElements() {
    return Array.from(
      this.panelTarget.querySelectorAll(
        'a[href], button:not([disabled]), input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])'
      )
    ).filter((element) => element.offsetParent !== null)
  }
}
