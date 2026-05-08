import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["frame", "panel", "percent", "toggleButton", "zoomInButton", "zoomOutButton"]

  connect() {
    this.zoom = 1
    this.minZoom = 1
    this.maxZoom = 4
    this.step = 0.25
    this.media = this.frameTarget.querySelector("img, video")
    this.update()
  }

  toggle() {
    if (this.panelTarget.classList.contains("hidden")) {
      this.show()
    } else {
      this.hide()
    }
  }

  show() {
    this.toggleButtonTarget.classList.add("hidden")
    this.panelTarget.classList.remove("hidden")
    this.panelTarget.classList.add("flex")
  }

  hide() {
    this.panelTarget.classList.add("hidden")
    this.panelTarget.classList.remove("flex")
    this.toggleButtonTarget.classList.remove("hidden")
  }

  zoomIn() {
    this.setZoom(this.zoom + this.step)
  }

  zoomOut() {
    this.setZoom(this.zoom - this.step)
  }

  reset() {
    this.setZoom(1)
  }

  setZoom(zoom) {
    this.zoom = Math.min(this.maxZoom, Math.max(this.minZoom, zoom))
    this.update()
  }

  update() {
    if (this.media) {
      this.media.style.transform = `scale(${this.zoom})`
      this.media.style.transformOrigin = "center center"
      this.media.style.transition = "transform 160ms ease"
    }

    this.percentTarget.textContent = `${Math.round(this.zoom * 100)}%`
    this.zoomOutButtonTarget.disabled = this.zoom <= this.minZoom
    this.zoomInButtonTarget.disabled = this.zoom >= this.maxZoom
  }
}
