import { Controller } from "@hotwired/stimulus"

const MEDIA_EXTENSIONS = [".heic", ".heif", ".jpg", ".jpeg", ".png", ".mov", ".mp4"]
const SIDECAR_EXTENSIONS = [".aae"]

export default class extends Controller {
  static targets = ["input", "summary", "submit"]

  connect() {
    this.updateSummary()
  }

  browse(event) {
    if (event?.currentTarget !== this.element) {
      event?.stopPropagation()
      this.inputTarget.click()
      return
    }

    if (event.target.closest("[data-drop-upload-ignore-browse]")) return

    this.inputTarget.click()
  }

  submit(event) {
    event.stopPropagation()

    if (this.submitTarget.disabled) {
      event.preventDefault()
      return
    }

    this.submitTarget.value = "Uploading..."
    this.submitTarget.disabled = true
    this.summaryTarget.textContent = "Uploading selected files..."
  }

  choose() {
    this.updateSummary()
  }

  dragover(event) {
    event.preventDefault()
    this.element.classList.add("border-teal-600", "bg-teal-50")
  }

  dragleave(event) {
    event.preventDefault()
    this.element.classList.remove("border-teal-600", "bg-teal-50")
  }

  drop(event) {
    event.preventDefault()
    this.element.classList.remove("border-teal-600", "bg-teal-50")

    const files = Array.from(event.dataTransfer.files).filter((file) => this.supported(file))
    const transfer = new DataTransfer()
    files.forEach((file) => transfer.items.add(file))
    this.inputTarget.files = transfer.files
    this.updateSummary()
  }

  updateSummary() {
    const files = Array.from(this.inputTarget.files)
    const mediaCount = files.filter((file) => MEDIA_EXTENSIONS.includes(this.extension(file))).length
    const sidecarCount = files.filter((file) => SIDECAR_EXTENSIONS.includes(this.extension(file))).length

    if (files.length === 0) {
      this.summaryTarget.textContent = "Drop iPhone imports here or choose files."
      this.submitTarget.disabled = true
      return
    }

    this.summaryTarget.textContent = `${mediaCount} media file${mediaCount === 1 ? "" : "s"} · ${sidecarCount} AAE sidecar${sidecarCount === 1 ? "" : "s"}`
    this.submitTarget.disabled = mediaCount === 0
  }

  supported(file) {
    return MEDIA_EXTENSIONS.concat(SIDECAR_EXTENSIONS).includes(this.extension(file))
  }

  extension(file) {
    const name = file.name.toLowerCase()
    const dot = name.lastIndexOf(".")
    return dot >= 0 ? name.slice(dot) : ""
  }
}
