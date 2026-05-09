import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = [
    "frame",
    "minimap",
    "minimapImage",
    "minimapViewport",
    "panel",
    "percent",
    "status",
    "toggleButton",
    "zoomInButton",
    "zoomOutButton"
  ]

  connect() {
    this.zoom = 1
    this.panX = 0
    this.panY = 0
    this.minZoom = 1
    this.maxZoom = 4
    this.step = 0.25
    this.panStep = 48
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
    this.frameTarget.tabIndex = this.zoom > this.minZoom ? 0 : -1
    this.percentTarget.textContent = `${Math.round(this.zoom * 100)}%`
    const status = this.statusText()
    if (this.statusTarget.textContent !== status) {
      this.statusTarget.textContent = status
    }
    this.zoomOutButtonTarget.disabled = this.zoom <= this.minZoom
    this.zoomInButtonTarget.disabled = this.zoom >= this.maxZoom
    this.updateMinimap()
  }

  keydown(event) {
    if (this.zoom <= this.minZoom) return

    const offsets = {
      ArrowLeft: [this.panStep, 0],
      ArrowRight: [-this.panStep, 0],
      ArrowUp: [0, this.panStep],
      ArrowDown: [0, -this.panStep]
    }
    const offset = offsets[event.key]
    if (!offset) return

    event.preventDefault()
    this.panX += offset[0]
    this.panY += offset[1]
    this.clampPan()
    this.update()
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

  updateMinimap() {
    if (!this.hasMinimapTarget || !this.media || this.zoom <= this.minZoom) {
      this.minimapTarget?.classList.add("hidden")
      return
    }

    if (this.media.tagName !== "IMG") {
      this.minimapTarget.classList.add("hidden")
      return
    }

    const source = this.media.currentSrc || this.media.src
    if (!source) {
      this.minimapTarget.classList.add("hidden")
      return
    }

    this.minimapTarget.classList.remove("hidden")
    const mediaWidth = this.media.naturalWidth || this.media.videoWidth || this.media.offsetWidth
    const mediaHeight = this.media.naturalHeight || this.media.videoHeight || this.media.offsetHeight
    this.minimapImageTarget.style.aspectRatio = `${mediaWidth} / ${mediaHeight}`
    this.minimapImageTarget.style.backgroundImage = `url("${source}")`
    this.minimapImageTarget.style.backgroundPosition = "center"
    this.minimapImageTarget.style.backgroundRepeat = "no-repeat"
    this.minimapImageTarget.style.backgroundSize = "contain"

    const frameRect = this.frameTarget.getBoundingClientRect()
    const scaledWidth = Math.max(1, this.media.offsetWidth * this.zoom)
    const scaledHeight = Math.max(1, this.media.offsetHeight * this.zoom)
    const viewportWidth = Math.min(100, (frameRect.width / scaledWidth) * 100)
    const viewportHeight = Math.min(100, (frameRect.height / scaledHeight) * 100)
    const centerX = 50 - (this.panX / scaledWidth) * 100
    const centerY = 50 - (this.panY / scaledHeight) * 100
    const left = Math.min(100 - viewportWidth, Math.max(0, centerX - viewportWidth / 2))
    const top = Math.min(100 - viewportHeight, Math.max(0, centerY - viewportHeight / 2))

    this.minimapViewportTarget.style.left = `${left}%`
    this.minimapViewportTarget.style.top = `${top}%`
    this.minimapViewportTarget.style.width = `${viewportWidth}%`
    this.minimapViewportTarget.style.height = `${viewportHeight}%`
  }

  statusText() {
    if (this.zoom <= this.minZoom) return "Zoom 100%."

    const horizontal = this.panX > this.panStep ? "left" : this.panX < -this.panStep ? "right" : "center"
    const vertical = this.panY > this.panStep ? "top" : this.panY < -this.panStep ? "bottom" : "middle"
    return `Zoom ${Math.round(this.zoom * 100)}%. View is near the ${vertical} ${horizontal} of the photo.`
  }
}
