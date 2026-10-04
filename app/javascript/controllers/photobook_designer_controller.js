import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["form", "layout", "primary", "secondary", "caption", "crop", "fit", "status", "photoSlot"]
  static values = { previewUrl: String }

  connect() {
    this.updateFields()
  }

  disconnect() {
    clearTimeout(this.previewTimer)
    this.previewRequest?.abort()
  }

  schedulePreview() {
    this.updateFields()
    clearTimeout(this.previewTimer)
    this.previewRequest?.abort()
    this.statusTarget.textContent = "Unsaved changes. Updating preview…"
    this.previewTimer = setTimeout(() => this.preview(), 350)
  }

  updateFields() {
    if (!this.hasLayoutTarget) return
    const layout = this.layoutTarget.value
    const twoPhotos = layout === "two_horizontal" || layout === "two_vertical"
    this.primaryTarget.hidden = layout === "blank" || layout === "text"
    this.secondaryTarget.hidden = !twoPhotos
    this.captionTarget.hidden = !twoPhotos && layout !== "caption" && layout !== "text"
    this.fitTarget.hidden = !twoPhotos && layout !== "caption"
    this.cropTarget.hidden = layout === "fit"
    if (this.hasPhotoSlotTarget) {
      this.photoSlotTarget.options[1].disabled = !twoPhotos
      if (!twoPhotos) this.photoSlotTarget.value = "primary"
    }
  }

  choosePhoto(event) {
    const slot = this.hasPhotoSlotTarget ? this.photoSlotTarget.value : "primary"
    const field = this.formTarget.querySelector(`[name="photo_book_page[${slot}_photo_id]"]`)
    if (!Array.from(field.options).some((option) => option.value === event.currentTarget.dataset.photoId)) {
      field.add(new Option(event.currentTarget.dataset.photoTitle, event.currentTarget.dataset.photoId))
    }
    field.value = event.currentTarget.dataset.photoId
    if (this.layoutTarget.value === "blank") this.layoutTarget.value = "caption"
    const captionName = slot === "primary" ? "caption" : "secondary_caption"
    const caption = this.formTarget.querySelector(`[name="photo_book_page[${captionName}]"]`)
    if (!caption.value) caption.value = event.currentTarget.dataset.caption || ""
    this.schedulePreview()
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
      const response = await fetch(this.previewUrlValue, {
        method: "POST", body: data, signal: request.signal,
        headers
      })
      if (!response.ok) throw new Error("Preview unavailable")
      const html = await response.text()
      if (request.signal.aborted) return
      window.Turbo.renderStreamMessage(html)
      this.statusTarget.textContent = "Preview updated. Save page to keep your changes."
    } catch (error) {
      if (error.name !== "AbortError") this.statusTarget.textContent = "Preview could not update. Your changes are still in the form; try saving the page."
    }
  }
}
