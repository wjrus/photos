import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = {
    backUrl: String,
    nextUrl: String,
    previousUrl: String
  }

  keydown(event) {
    if (event.defaultPrevented || event.repeat || event.isComposing) return
    if (event.altKey || event.ctrlKey || event.metaKey || event.shiftKey) return
    if (event.target.isContentEditable) return
    if (event.target.closest?.("input, select, textarea, video, audio, [role='slider'], [role='dialog'], dialog, #photo-info-panel")) return

    const url = {
      ArrowLeft: this.previousUrlValue,
      ArrowRight: this.nextUrlValue,
      Escape: this.backUrlValue
    }[event.key]
    if (!url) return

    event.preventDefault()
    if (window.Turbo) {
      window.Turbo.visit(url, event.key === "Escape" ? {} : { action: "replace" })
    } else {
      window.location.href = url
    }
  }
}
