import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["frame", "panel", "percent", "toggleButton", "zoomInButton", "zoomOutButton"]

  connect() {
    this.zoom = 1
    this.panX = 0
    this.panY = 0
    this.minZoom = 1
    this.maxZoom = 4
    this.step = 0.25
    this.media = this.frameTarget.querySelector("img, video")
    this.dragging = false
    this.frameTarget.addEventListener("pointerdown", this.pointerdown)
    this.frameTarget.addEventListener("pointermove", this.pointermove)
    this.frameTarget.addEventListener("pointerup", this.pointerup)
    this.frameTarget.addEventListener("pointercancel", this.pointerup)
    window.addEventListener("resize", this.resize)
    this.update()
  }

  disconnect() {
    this.frameTarget.removeEventListener("pointerdown", this.pointerdown)
    this.frameTarget.removeEventListener("pointermove", this.pointermove)
    this.frameTarget.removeEventListener("pointerup", this.pointerup)
    this.frameTarget.removeEventListener("pointercancel", this.pointerup)
    window.removeEventListener("resize", this.resize)
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
    if (this.zoom <= this.minZoom) {
      this.panX = 0
      this.panY = 0
    } else {
      this.clampPan()
    }
    this.update()
  }

  update() {
    if (this.media) {
      this.media.style.transform = `translate3d(${this.panX}px, ${this.panY}px, 0) scale(${this.zoom})`
      this.media.style.transformOrigin = "center center"
      this.media.style.transition = this.dragging ? "none" : "transform 160ms ease"
      this.media.style.cursor = this.zoom > this.minZoom ? (this.dragging ? "grabbing" : "grab") : ""
      this.media.style.userSelect = this.zoom > this.minZoom ? "none" : ""
      this.media.style.touchAction = this.zoom > this.minZoom ? "none" : ""
    }

    this.frameTarget.classList.toggle("cursor-grab", this.zoom > this.minZoom && !this.dragging)
    this.frameTarget.classList.toggle("cursor-grabbing", this.zoom > this.minZoom && this.dragging)
    this.frameTarget.dataset.photoZoomPannable = this.zoom > this.minZoom ? "true" : "false"
    this.percentTarget.textContent = `${Math.round(this.zoom * 100)}%`
    this.zoomOutButtonTarget.disabled = this.zoom <= this.minZoom
    this.zoomInButtonTarget.disabled = this.zoom >= this.maxZoom
  }

  pointerdown = (event) => {
    if (this.zoom <= this.minZoom || event.button !== 0 || this.isInteractiveElement(event.target)) return

    event.preventDefault()
    event.stopPropagation()
    this.dragging = true
    this.dragStartX = event.clientX
    this.dragStartY = event.clientY
    this.dragStartPanX = this.panX
    this.dragStartPanY = this.panY
    this.frameTarget.setPointerCapture(event.pointerId)
    this.update()
  }

  pointermove = (event) => {
    if (!this.dragging) return

    event.preventDefault()
    event.stopPropagation()
    this.panX = this.dragStartPanX + event.clientX - this.dragStartX
    this.panY = this.dragStartPanY + event.clientY - this.dragStartY
    this.clampPan()
    this.update()
  }

  pointerup = (event) => {
    if (!this.dragging) return

    event.preventDefault()
    event.stopPropagation()
    this.dragging = false
    if (this.frameTarget.hasPointerCapture(event.pointerId)) {
      this.frameTarget.releasePointerCapture(event.pointerId)
    }
    this.update()
  }

  resize = () => {
    this.clampPan()
    this.update()
  }

  clampPan() {
    if (!this.media) return

    const frameRect = this.frameTarget.getBoundingClientRect()
    const maxPanX = Math.max(0, (this.media.offsetWidth * this.zoom - frameRect.width) / 2)
    const maxPanY = Math.max(0, (this.media.offsetHeight * this.zoom - frameRect.height) / 2)
    this.panX = Math.min(maxPanX, Math.max(-maxPanX, this.panX))
    this.panY = Math.min(maxPanY, Math.max(-maxPanY, this.panY))
  }

  isInteractiveElement(element) {
    return element.closest("a, button, input, select, textarea, summary, [role='button']")
  }
}
