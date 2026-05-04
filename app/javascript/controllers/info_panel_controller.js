import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["backdrop", "button", "panel", "viewer"]

  connect() {
    if (this.storedOpen()) {
      this.show()
    } else {
      this.close()
    }
  }

  toggle() {
    if (this.open) {
      this.close()
    } else {
      this.show()
    }
  }

  show() {
    this.open = true
    this.storeOpen(true)
    this.panelTarget.classList.remove("translate-x-full")
    this.panelTarget.classList.add("translate-x-0")
    this.backdropTarget.classList.remove("hidden")
    this.buttonTarget.setAttribute("aria-expanded", "true")
    this.viewerTarget.classList.add("info-panel-open")
  }

  close() {
    this.open = false
    this.storeOpen(false)
    this.panelTarget.classList.add("translate-x-full")
    this.panelTarget.classList.remove("translate-x-0")
    this.backdropTarget.classList.add("hidden")
    this.buttonTarget.setAttribute("aria-expanded", "false")
    this.viewerTarget.classList.remove("info-panel-open")
  }

  storedOpen() {
    return window.sessionStorage?.getItem("photos.infoPanelOpen") === "true"
  }

  storeOpen(open) {
    window.sessionStorage?.setItem("photos.infoPanelOpen", open ? "true" : "false")
  }
}
