import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = {
    backUrl: String,
    nextUrl: String,
    previousUrl: String
  }

  connect() {
    this.startY = null
    this.lastWheelAt = 0
    this.animating = false
    this.animateEntry()
  }

  keydown(event) {
    if (this.insideInfoPanel(event)) return
    if (this.interactiveElement(event)) return
    if (this.editingText(event)) return

    if (event.key === "Escape") {
      event.preventDefault()
      this.leaveStream()
    }

    if (event.key === "ArrowDown") {
      event.preventDefault()
      this.navigateTo(this.nextUrlValue, "next")
    }

    if (event.key === "ArrowUp") {
      event.preventDefault()
      this.navigateTo(this.previousUrlValue, "previous")
    }
  }

  touchstart(event) {
    if (this.panningZoomedMedia(event)) return

    this.startY = event.changedTouches[0]?.clientY
  }

  touchend(event) {
    if (this.panningZoomedMedia(event)) {
      this.startY = null
      return
    }

    if (this.startY === null) return

    const endY = event.changedTouches[0]?.clientY
    if (endY === undefined) return

    const deltaY = endY - this.startY
    this.startY = null

    if (Math.abs(deltaY) < 50) return

    if (deltaY < 0) {
      this.navigateTo(this.nextUrlValue, "next")
    } else {
      this.navigateTo(this.previousUrlValue, "previous")
    }
  }

  wheel(event) {
    if (this.insideInfoPanel(event)) return
    if (this.editingText(event)) return
    if (this.panningZoomedMedia(event)) return

    const absX = Math.abs(event.deltaX)
    const absY = Math.abs(event.deltaY)
    if (absY < 35 || absY < absX) return

    const now = Date.now()
    if (now - this.lastWheelAt < 650) return

    this.lastWheelAt = now

    if (event.deltaY > 0) {
      this.navigateTo(this.nextUrlValue, "next")
    } else {
      this.navigateTo(this.previousUrlValue, "previous")
    }
  }

  next(event) {
    event.preventDefault()
    this.navigateTo(this.nextUrlValue || event.currentTarget.href, "next")
  }

  previous(event) {
    event.preventDefault()
    this.navigateTo(this.previousUrlValue || event.currentTarget.href, "previous")
  }

  leaveStream() {
    this.visit(this.backUrlValue)
  }

  visit(url, options = {}) {
    if (!url) return

    if (window.Turbo) {
      window.Turbo.visit(url, options)
    } else {
      window.location.href = url
    }
  }

  navigateTo(url, direction) {
    if (!url || this.animating) return

    if (!this.shouldAnimate()) {
      this.visit(url, { action: "replace" })
      return
    }

    this.animating = true
    this.storeDirection(direction)
    this.element.classList.add(`photo-viewer-shell--exit-${direction}`)

    window.setTimeout(() => {
      this.visit(url, { action: "replace" })
    }, 170)
  }

  animateEntry() {
    const direction = this.takeStoredDirection()
    if (!direction || !this.shouldAnimate()) return

    this.element.classList.add(`photo-viewer-shell--enter-${direction}`)
    this.element.getBoundingClientRect()

    requestAnimationFrame(() => {
      this.element.classList.add("photo-viewer-shell--entered")
      window.setTimeout(() => {
        this.element.classList.remove(`photo-viewer-shell--enter-${direction}`, "photo-viewer-shell--entered")
      }, 220)
    })
  }

  shouldAnimate() {
    return window.matchMedia("(max-width: 767px)").matches &&
      !window.matchMedia("(prefers-reduced-motion: reduce)").matches
  }

  storeDirection(direction) {
    try {
      window.sessionStorage.setItem("photoViewerNavigationDirection", direction)
    } catch (_error) {
      // Ignore private browsing/storage failures; navigation still works.
    }
  }

  takeStoredDirection() {
    try {
      const direction = window.sessionStorage.getItem("photoViewerNavigationDirection")
      window.sessionStorage.removeItem("photoViewerNavigationDirection")
      return ["next", "previous"].includes(direction) ? direction : null
    } catch (_error) {
      return null
    }
  }

  editingText(event) {
    const tagName = event.target.tagName
    return ["INPUT", "SELECT", "TEXTAREA"].includes(tagName) || event.target.isContentEditable
  }

  interactiveElement(event) {
    return event.target.closest?.("a, button, summary, [role='button']")
  }

  insideInfoPanel(event) {
    return event.target.closest?.("#photo-info-panel")
  }

  panningZoomedMedia(event) {
    return event.target.closest?.("[data-photo-zoom-pannable='true']")
  }
}
