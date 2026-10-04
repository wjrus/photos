import { Controller } from "@hotwired/stimulus"

const PHOTO_DRAG_TYPE = "application/x-photos-photobook"
const TWO_PHOTO_LAYOUTS = ["two_horizontal", "two_vertical"]

export default class extends Controller {
  static targets = ["form", "layout", "primary", "secondary", "caption", "crop", "fit", "status", "photoInput", "slot", "primaryCaption", "secondaryCaption", "addPhoto", "tray", "trayPhoto", "captionToggle", "showCaptions", "secondaryCaptionField", "textStyle", "coverPosition", "coverFocusX", "coverFocusY", "coverCropHandle"]
  static values = { previewUrl: String, trayUrl: String }

  connect() {
    this.dirty = false
    this.trayPage = 1
    this.traySearch = ""
    this.showUsed = false
    this.previousCoverLayout = this.hasLayoutTarget ? this.layoutTarget.value : null
    this.updateFields()
    this.placementKey = this.currentPlacementKey()
  }

  disconnect() {
    this.coverDrag = null
    clearTimeout(this.previewTimer)
    this.previewRequest?.abort()
    this.trayRequest?.abort()
  }

  trayPhotoTargetConnected(button) {
    button.setAttribute("aria-pressed", String(button.dataset.photoId === this.selectedPhoto?.id))
    // Turbo renders streams asynchronously. A response already queued before an
    // edit must not put a newly placed photo back into the unused tray.
    if (this.placementKey !== undefined && !this.showUsed && this.activePhotoIds().includes(button.dataset.photoId)) button.hidden = true
  }

  saving() {
    this.dirty = false
    clearTimeout(this.previewTimer)
    this.previewRequest?.abort()
    this.trayRequest?.abort()
  }

  beforeVisit(event) {
    if (this.dirty && !window.confirm("This page has unsaved changes. Leave without saving?")) event.preventDefault()
  }

  beforePreviewRender(event) {
    // A preview already queued by Turbo must not replace the captured pointer
    // while positioning a cover. Releasing the pointer requests a fresh preview.
    if (this.coverDrag && event.target.getAttribute("target") === "photobook-preview") event.preventDefault()
  }

  schedulePreview(event) {
    this.dirty = true
    this.updateCoverColors(event)
    this.updateFields()
    clearTimeout(this.previewTimer)
    this.previewRequest?.abort()
    this.statusTarget.textContent = "Unsaved changes. Updating preview…"
    this.previewTimer = setTimeout(() => this.preview(), 350)
    const key = this.currentPlacementKey()
    if (key !== this.placementKey) {
      this.placementKey = key
      this.trayPage = 1
      this.syncTray()
      this.refreshTray()
    }
  }

  updateFields() {
    if (!this.hasLayoutTarget) return
    if (this.isCover) {
      this.coverPositionTarget.hidden = this.layoutTarget.value !== "full" || !this.activePhotoIds().length
      return
    }
    const layout = this.layoutTarget.value
    const twoPhotos = TWO_PHOTO_LAYOUTS.includes(layout)
    const captionLayout = twoPhotos || layout === "caption"
    this.captionToggleTarget.hidden = !captionLayout
    this.primaryTarget.hidden = layout === "blank" || layout === "text"
    this.secondaryTarget.hidden = !twoPhotos
    this.captionTarget.hidden = layout !== "text" && (!captionLayout || !this.showCaptionsTarget.checked)
    this.secondaryCaptionFieldTarget.hidden = !this.showCaptionsTarget.checked
    this.fitTarget.hidden = !twoPhotos && layout !== "caption"
    this.cropTarget.hidden = layout === "fit"
    this.addPhotoTarget.hidden = twoPhotos || layout === "blank" || layout === "text"
  }

  updateCoverColors(event) {
    if (!this.isCover || !this.hasTextStyleTarget) return
    const style = this.textStyleTarget
    const setting = event?.target?.dataset.styleSetting
    if (setting === "color") style.dataset.autoColor = "false"
    if (setting === "shadow") style.dataset.autoShadow = "false"
    if (this.previousCoverLayout !== this.layoutTarget.value) {
      const full = this.layoutTarget.value === "full"
      if (style.dataset.autoColor === "true") style.querySelector('[data-style-setting="color"]').value = full ? "#ffffff" : style.dataset.pageTextColor
      if (style.dataset.autoShadow === "true") style.querySelector('[data-style-setting="shadow"]').checked = full
      this.previousCoverLayout = this.layoutTarget.value
    }
  }

  applyTextPreset(event) {
    const style = this.textStyleTarget
    const preset = event.currentTarget.dataset.stylePreset
    const full = this.layoutTarget.value === "full"
    const values = {
      font: { classic: "garamond", editorial: "serif", minimal: "lato" }[preset],
      size: style.dataset.back === "true" ? "20" : preset === "editorial" ? "32" : "42",
      alignment: preset === "editorial" ? "left" : "center",
      position: preset === "minimal" ? "top" : "bottom",
      color: full ? "#ffffff" : style.dataset.pageTextColor,
      shadow_color: "#000000"
    }
    Object.entries(values).forEach(([key, value]) => { style.querySelector(`[data-style-setting="${key}"]`).value = value })
    style.querySelector('[data-style-setting="shadow"]').checked = full
    style.dataset.autoColor = "true"
    style.dataset.autoShadow = "true"
    this.schedulePreview()
  }

  get isCover() {
    return this.hasFormTarget && this.formTarget.dataset.cover === "true"
  }

  currentPlacementKey() {
    return JSON.stringify(this.activePhotoIds())
  }

  activePhotoIds() {
    if (!this.hasFormTarget) return []
    const layout = this.layoutTarget.value
    if (!this.isCover && ["blank", "text"].includes(layout)) return []
    const inputs = this.isCover || TWO_PHOTO_LAYOUTS.includes(layout) ? this.photoInputTargets : this.photoInputTargets.filter((input) => input.dataset.photoSlot === "primary")
    return [...new Set(inputs.map((input) => input.value).filter(Boolean))].sort()
  }

  photoData(button) {
    return { id: button.dataset.photoId, title: button.dataset.photoTitle, imageUrl: button.dataset.imageUrl, caption: button.dataset.caption }
  }

  selectPhoto(event) {
    if (performance.now() < (this.ignoreClickUntil || 0)) return
    const photo = this.photoData(event.currentTarget)
    this.selectedPhoto = this.selectedPhoto?.id === photo.id ? null : photo
    this.trayPhotoTargets.forEach((button) => button.setAttribute("aria-pressed", String(button.dataset.photoId === this.selectedPhoto?.id)))
    this.statusTarget.textContent = this.selectedPhoto ? `${photo.title} selected. Select a photo area to place it.` : "Photo selection cleared."
  }

  dragStart(event) {
    this.draggedPhoto = this.photoData(event.currentTarget)
    event.dataTransfer.setData(PHOTO_DRAG_TYPE, this.draggedPhoto.id)
    event.dataTransfer.effectAllowed = "copy"
    this.element.classList.add("is-dragging")
    this.ignoreClickUntil = performance.now() + 300
  }

  dragEnd() {
    this.draggedPhoto = null
    this.element.classList.remove("is-dragging")
    this.element.querySelectorAll(".is-drag-over").forEach((area) => area.classList.remove("is-drag-over"))
    this.ignoreClickUntil = performance.now() + 300
  }

  dragOver(event) {
    if (!this.draggedPhoto) return
    event.preventDefault()
    event.dataTransfer.dropEffect = "copy"
    event.currentTarget.classList.add("is-drag-over")
  }

  dragLeave(event) {
    if (!event.currentTarget.contains(event.relatedTarget)) event.currentTarget.classList.remove("is-drag-over")
  }

  dropPhoto(event) {
    event.preventDefault()
    if (!this.draggedPhoto || event.dataTransfer.getData(PHOTO_DRAG_TYPE) !== this.draggedPhoto.id) return
    this.placePhoto(this.draggedPhoto, event.currentTarget.dataset.photoSlot)
    this.dragEnd()
  }

  chooseSlot(event) {
    if (performance.now() < (this.ignoreClickUntil || 0)) return
    if (this.selectedPhoto) this.placePhoto(this.selectedPhoto, event.currentTarget.dataset.photoSlot)
    else if (event.currentTarget.dataset.coverReposition === "true") this.statusTarget.textContent = "Drag the photo to position it, or use the position sliders. Select a tray photo to replace it."
    else this.statusTarget.textContent = "Select a photo in the tray first, or drag a photo into this area."
  }

  coverCropHandleTargetConnected(handle) {
    if (this.restoreCoverFocus) {
      if (document.activeElement === document.body) handle.focus({ preventScroll: true })
      this.restoreCoverFocus = false
    }
  }

  coverGeometry(handle) {
    if (!this.isCover || this.layoutTarget.value !== "full" || handle.dataset.coverReposition !== "true" || this.selectedPhoto || this.draggedPhoto) return null
    const svg = handle.parentElement.querySelector("svg")
    const image = svg?.querySelector("image")
    if (!image || image.dataset.photoId !== this.photoInputTargets[0].value) return null
    const box = svg.getBoundingClientRect()
    const view = svg.viewBox.baseVal
    return {
      image, scaleX: view.width / box.width, scaleY: view.height / box.height,
      overflowX: Math.max(0, Number(image.getAttribute("width")) - view.width),
      overflowY: Math.max(0, Number(image.getAttribute("height")) - view.height)
    }
  }

  setCoverPosition(x, y, geometry) {
    this.coverFocusXTarget.value = Math.round(Math.max(0, Math.min(100, x)))
    this.coverFocusYTarget.value = Math.round(Math.max(0, Math.min(100, y)))
    if (geometry) {
      geometry.image.setAttribute("x", -geometry.overflowX * Number(this.coverFocusXTarget.value) / 100)
      geometry.image.setAttribute("y", -geometry.overflowY * Number(this.coverFocusYTarget.value) / 100)
    }
  }

  startCoverDrag(event) {
    if (!event.isPrimary || event.button !== 0) return
    const geometry = this.coverGeometry(event.currentTarget)
    if (!geometry || (!geometry.overflowX && !geometry.overflowY)) return
    clearTimeout(this.previewTimer)
    this.previewRequest?.abort()
    this.coverDrag = {
      ...geometry, handle: event.currentTarget, pointerId: event.pointerId,
      startX: event.clientX, startY: event.clientY,
      focusX: Number(this.coverFocusXTarget.value), focusY: Number(this.coverFocusYTarget.value),
      dirty: this.dirty, status: this.statusTarget.textContent, moved: false
    }
    event.currentTarget.setPointerCapture(event.pointerId)
  }

  moveCoverDrag(event) {
    const drag = this.coverDrag
    if (!drag || event.pointerId !== drag.pointerId) return
    const dx = event.clientX - drag.startX
    const dy = event.clientY - drag.startY
    if (!drag.moved && Math.hypot(dx, dy) < 3) return
    event.preventDefault()
    drag.moved = true
    drag.handle.classList.add("is-repositioning")
    this.setCoverPosition(
      drag.overflowX ? drag.focusX - dx * drag.scaleX / drag.overflowX * 100 : drag.focusX,
      drag.overflowY ? drag.focusY - dy * drag.scaleY / drag.overflowY * 100 : drag.focusY,
      drag
    )
    this.dirty = true
    this.statusTarget.textContent = "Unsaved photo position. Save to keep your changes."
  }

  endCoverDrag(event) {
    const drag = this.coverDrag
    if (!drag || event.pointerId !== drag.pointerId) return
    this.releaseCoverDrag(drag)
    if (drag.moved) this.ignoreClickUntil = performance.now() + 300
    if (drag.moved || drag.dirty) this.schedulePreview()
  }

  cancelCoverDrag(event) {
    const drag = this.coverDrag
    if (!drag || event.pointerId !== drag.pointerId) return
    this.setCoverPosition(drag.focusX, drag.focusY, drag)
    this.dirty = drag.dirty
    this.statusTarget.textContent = drag.status
    this.releaseCoverDrag(drag)
    if (drag.dirty) this.schedulePreview()
  }

  releaseCoverDrag(drag) {
    this.coverDrag = null
    drag.handle.classList.remove("is-repositioning")
    if (drag.handle.hasPointerCapture(drag.pointerId)) drag.handle.releasePointerCapture(drag.pointerId)
  }

  nudgeCoverPhoto(event) {
    const directions = { ArrowLeft: [1, 0], ArrowRight: [-1, 0], ArrowUp: [0, 1], ArrowDown: [0, -1] }
    const direction = directions[event.key]
    const geometry = direction && this.coverGeometry(event.currentTarget)
    if (!geometry) return
    event.preventDefault()
    const step = event.shiftKey ? 10 : 1
    this.setCoverPosition(
      Number(this.coverFocusXTarget.value) + (geometry.overflowX ? direction[0] * step : 0),
      Number(this.coverFocusYTarget.value) + (geometry.overflowY ? direction[1] * step : 0),
      geometry
    )
    this.restoreCoverFocus = true
    this.schedulePreview()
  }

  centerCoverPhoto() {
    this.setCoverPosition(50, 50, this.hasCoverCropHandleTarget ? this.coverGeometry(this.coverCropHandleTarget) : null)
    this.schedulePreview()
  }

  placePhoto(photo, slot) {
    const input = this.photoInputTargets.find((field) => field.dataset.photoSlot === slot)
    if (!input) return
    if (this.isCover && input.value !== photo.id) this.setCoverPosition(50, 50)
    if (!this.isCover) {
      if (["blank", "text"].includes(this.layoutTarget.value)) this.layoutTarget.value = "caption"
      if (slot === "secondary" && !TWO_PHOTO_LAYOUTS.includes(this.layoutTarget.value)) this.layoutTarget.value = "two_horizontal"
      const caption = slot === "primary" ? this.primaryCaptionTarget : this.secondaryCaptionTarget
      if (!caption.value) caption.value = photo.caption || ""
    }
    input.value = photo.id
    const tile = this.slotTargets.find((area) => area.dataset.photoSlot === slot)
    tile.querySelector("img").src = photo.imageUrl
    tile.querySelector("img").hidden = false
    tile.querySelector(".photobook-slot-title").textContent = photo.title
    tile.querySelector(".photobook-remove-photo").hidden = false
    this.selectedPhoto = null
    this.trayPhotoTargets.forEach((button) => button.setAttribute("aria-pressed", "false"))
    this.schedulePreview()
    tile.querySelector(".photobook-slot-button").focus({ preventScroll: true })
  }

  removePhoto(event) {
    const slot = event.currentTarget.dataset.photoSlot
    this.photoInputTargets.find((input) => input.dataset.photoSlot === slot).value = ""
    const tile = this.slotTargets.find((area) => area.dataset.photoSlot === slot)
    tile.querySelector("img").hidden = true
    tile.querySelector("img").removeAttribute("src")
    tile.querySelector(".photobook-slot-title").textContent = "Drop a photo here"
    event.currentTarget.hidden = true
    this.schedulePreview()
  }

  addSecondPhoto() {
    this.layoutTarget.value = "two_horizontal"
    this.schedulePreview()
    this.secondaryTarget.querySelector("button").focus()
  }

  syncTray() {
    if (this.showUsed) return
    const placed = this.activePhotoIds()
    this.trayPhotoTargets.forEach((button) => { if (placed.includes(button.dataset.photoId)) button.hidden = true })
  }

  searchTray(event) {
    event.preventDefault()
    const form = event.target.closest("form")
    this.traySearch = form.querySelector('[name="tray_search"]').value
    this.showUsed = form.querySelector('[name="show_used"]').checked
    this.trayPage = 1
    this.selectedPhoto = null
    this.refreshTray()
  }

  browseTray(event) {
    event.preventDefault()
    this.trayPage = Number(event.currentTarget.dataset.trayPage)
    this.refreshTray()
  }

  async refreshTray() {
    this.trayRequest?.abort()
    const request = new AbortController()
    this.trayRequest = request
    const url = new URL(this.trayUrlValue, window.location.origin)
    const data = new FormData(this.formTarget)
    // Tray requests need placement state only. Keep caption text and CSRF tokens
    // out of GET URLs, and keep the editor intact while browsing the tray.
    for (const [key, value] of data) {
      if (["page_id", "preview_key"].includes(key) || /\[(primary_photo_id|secondary_photo_id|cover_photo_id|back_photo_id|layout|cover_layout)\]$/.test(key)) url.searchParams.set(key, value)
    }
    url.searchParams.set("tray_search", this.traySearch)
    url.searchParams.set("tray_page", this.trayPage)
    url.searchParams.set("show_used", this.showUsed ? "1" : "0")
    this.trayTarget.setAttribute("aria-busy", "true")
    try {
      const response = await fetch(url, { headers: { "Accept": "text/vnd.turbo-stream.html" }, signal: request.signal })
      if (!response.ok) throw new Error("Tray unavailable")
      const html = await response.text()
      if (!request.signal.aborted) window.Turbo.renderStreamMessage(html)
    } catch (error) {
      if (error.name !== "AbortError") this.statusTarget.textContent = "The photo tray could not refresh. Your edits are still in the form. Try finding photos again."
    } finally {
      if (this.trayRequest === request && this.hasTrayTarget) this.trayTarget.removeAttribute("aria-busy")
    }
  }

  async preview() {
    const request = new AbortController()
    this.previewRequest = request
    const data = new FormData(this.formTarget)
    data.delete("_method")
    const headers = { "Accept": "text/vnd.turbo-stream.html" }
    const token = document.querySelector('meta[name="csrf-token"]')?.content
    if (token) headers["X-CSRF-Token"] = token
    try {
      const response = await fetch(this.previewUrlValue, { method: "POST", body: data, signal: request.signal, headers })
      if (!response.ok) throw new Error("Preview unavailable")
      const html = await response.text()
      if (request.signal.aborted) return
      window.Turbo.renderStreamMessage(html)
      this.statusTarget.textContent = "Preview updated. Save to keep your changes."
    } catch (error) {
      if (error.name !== "AbortError") this.statusTarget.textContent = "Preview could not update. Your changes are still in the form; try saving."
    }
  }
}
