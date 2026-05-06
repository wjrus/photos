import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  go(event) {
    if (!this.canReturnWithinApp()) return

    event.preventDefault()
    window.history.back()
  }

  canReturnWithinApp() {
    if (window.history.length <= 1) return false
    return Boolean(window.history.state?.turbo)
  }
}
