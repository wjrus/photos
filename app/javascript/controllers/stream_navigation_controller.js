import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = {
    backUrl: String,
    nextUrl: String,
    previousUrl: String
  }

  connect() {
    this.startY = null
  }

  keydown(event) {
    if (this.editingText(event)) return

    if (event.key === "Escape") {
      event.preventDefault()
      this.goBack()
    }

    if (event.key === "ArrowDown") {
      event.preventDefault()
      this.visit(this.nextUrlValue)
    }

    if (event.key === "ArrowUp") {
      event.preventDefault()
      this.visit(this.previousUrlValue)
    }
  }

  touchstart(event) {
    this.startY = event.changedTouches[0]?.clientY
  }

  touchend(event) {
    if (this.startY === null) return

    const endY = event.changedTouches[0]?.clientY
    if (endY === undefined) return

    const deltaY = endY - this.startY
    this.startY = null

    if (Math.abs(deltaY) < 50) return

    if (deltaY < 0) {
      this.visit(this.nextUrlValue)
    } else {
      this.visit(this.previousUrlValue)
    }
  }

  goBack() {
    if (window.history.length > 1) {
      window.history.back()
      return
    }

    this.visit(this.backUrlValue)
  }

  visit(url) {
    if (!url) return

    if (window.Turbo) {
      window.Turbo.visit(url)
    } else {
      window.location.href = url
    }
  }

  editingText(event) {
    const tagName = event.target.tagName
    return ["INPUT", "SELECT", "TEXTAREA"].includes(tagName) || event.target.isContentEditable
  }
}
