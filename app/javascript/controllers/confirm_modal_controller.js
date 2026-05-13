import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["dialog", "panel"]

  connect() {
    this.restoreFocusTo = null
    this.dialog = this.dialogTarget
    this.panel = this.panelTarget
    this.placeholder = document.createComment("confirm-modal")
    this.boundDialogClick = this.dialogClick.bind(this)
    this.dialog.addEventListener("click", this.boundDialogClick)
    this.close()
  }

  disconnect() {
    this.close()
    this.dialog.removeEventListener("click", this.boundDialogClick)

    if (this.dialog.parentNode === document.body) {
      this.dialog.remove()
    } else if (this.placeholder.parentNode && this.dialog.parentNode !== this.element) {
      this.placeholder.replaceWith(this.dialog)
    }
  }

  open(event) {
    this.restoreFocusTo = event?.currentTarget || document.activeElement
    this.prepareSubmitButtons()
    this.moveDialogToBody()
    this.dialog.classList.remove("hidden")
    this.dialog.classList.add("flex")
    document.body.classList.add("overflow-hidden")
    this.focusFirstControl()
  }

  close() {
    this.dialog.classList.add("hidden")
    this.dialog.classList.remove("flex")
    document.body.classList.remove("overflow-hidden")

    if (this.restoreFocusTo?.isConnected) {
      this.restoreFocusTo.focus()
    }
  }

  backdrop(event) {
    if (!this.panel.contains(event.target)) {
      this.close()
    }
  }

  dialogClick(event) {
    const closeButton = event.target.closest("[data-action~='confirm-modal#close']")
    if (closeButton && this.dialog.contains(closeButton)) {
      event.preventDefault()
      this.close()
      return
    }

    if (!this.panel.contains(event.target)) {
      this.close()
    }
  }

  keydown(event) {
    if (this.dialog.classList.contains("hidden")) return

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
      this.panel.focus()
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
      this.panel.querySelectorAll(
        'a[href], button:not([disabled]), input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])'
      )
    ).filter((element) => element.offsetParent !== null)
  }

  moveDialogToBody() {
    if (this.dialog.parentNode === document.body) return

    this.dialog.replaceWith(this.placeholder)
    document.body.appendChild(this.dialog)
  }

  prepareSubmitButtons() {
    const form = this.element.closest("form")
    if (!form?.id) return

    this.dialog.querySelectorAll("button[type='submit']:not([form])").forEach((button) => {
      button.setAttribute("form", form.id)
    })
  }
}
