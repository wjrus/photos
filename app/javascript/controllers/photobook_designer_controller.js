import { Controller } from "@hotwired/stimulus"

const PHOTO_DRAG_TYPE = "application/x-photos-photobook"
const TWO_PHOTO_LAYOUTS = ["two_horizontal", "two_vertical"]

export default class extends Controller {
  static targets = ["form", "layout", "primary", "secondary", "caption", "crop", "fit", "status", "photoInput", "slot", "primaryCaption", "secondaryCaption", "addPhoto", "tray", "trayPhoto", "captionToggle", "showCaptions", "secondaryCaptionField", "textStyle"]
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
    if (!this.hasLayoutTarget || this.isCover) return
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
    if (this.selectedPhoto) this.placePhoto(this.selectedPhoto, event.currentTarget.dataset.photoSlot)
    else this.statusTarget.textContent = "Select a photo in the tray first, or drag a photo into this area."
  }

  placePhoto(photo, slot) {
    const input = this.photoInputTargets.find((field) => field.dataset.photoSlot === slot)
    if (!input) return
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
