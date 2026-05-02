import { Controller } from "@hotwired/stimulus"

const MEDIA_EXTENSIONS = [".heic", ".heif", ".jpg", ".jpeg", ".png", ".mov", ".mp4"]
const SIDECAR_EXTENSIONS = [".aae"]
const CHUNK_SIZE = 16 * 1024 * 1024
const CHUNK_RETRIES = 3
const SESSION_KEY = "photos.resumableUpload"
const SESSION_TTL = 5 * 60 * 1000

export default class extends Controller {
  static targets = ["input", "summary", "submit", "fileList"]

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

  stop(event) {
    event.stopPropagation()
  }

  async submit(event) {
    event.stopPropagation()
    event.preventDefault()

    if (this.submitTarget.disabled) {
      return
    }

    const files = Array.from(this.inputTarget.files)
    const session = this.uploadSession(files)

    this.setUploading("Preparing upload...")

    try {
      const existingChunks = await this.uploadStatus(session.upload_id, session.files)

      for (let fileIndex = 0; fileIndex < files.length; fileIndex += 1) {
        await this.uploadFile(session.upload_id, session.files[fileIndex], files[fileIndex], fileIndex, files.length, existingChunks)
      }

      session.files.forEach((file) => this.updateFileProgress(file.file_id, 100, "done"))
      const response = await this.completeUpload(session.upload_id, session.files)
      this.clearUploadSession()
      window.location.assign(response.redirect_url)
    } catch (error) {
      this.summaryTarget.textContent = error.message
      this.submitTarget.value = "Upload"
      this.submitTarget.disabled = false
      this.markActiveFileFailed(error.message)
    }
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
      this.fileListTarget.replaceChildren()
      return
    }

    this.summaryTarget.textContent = `${mediaCount} media file${mediaCount === 1 ? "" : "s"} · ${sidecarCount} AAE sidecar${sidecarCount === 1 ? "" : "s"}`
    this.submitTarget.disabled = mediaCount === 0
    this.renderFileList(files)
  }

  async uploadFile(uploadId, manifest, file, fileIndex, totalFiles, existingChunks) {
    const uploadedChunks = new Set(existingChunks[manifest.file_id] || [])
    this.activeFileId = manifest.file_id
    this.updateFileProgress(manifest.file_id, this.filePercent(uploadedChunks.size, manifest.total_chunks), uploadedChunks.size > 0 ? "resuming" : "uploading")

    for (let chunkIndex = 0; chunkIndex < manifest.total_chunks; chunkIndex += 1) {
      if (uploadedChunks.has(chunkIndex)) {
        this.summaryTarget.textContent = `Resuming ${fileIndex + 1}/${totalFiles}: ${file.name} (${chunkIndex + 1}/${manifest.total_chunks})`
        continue
      }

      const start = chunkIndex * CHUNK_SIZE
      const chunk = file.slice(start, start + CHUNK_SIZE)
      const formData = new FormData()
      formData.append("upload_id", uploadId)
      formData.append("file_id", manifest.file_id)
      formData.append("chunk_index", chunkIndex)
      formData.append("chunk", chunk, file.name)

      this.summaryTarget.textContent = `Uploading ${fileIndex + 1}/${totalFiles}: ${file.name} (${chunkIndex + 1}/${manifest.total_chunks})`
      await this.withRetries(() => this.postForm("/upload_chunks", formData))
      this.updateFileProgress(manifest.file_id, this.filePercent(chunkIndex + 1, manifest.total_chunks), "uploading")
    }

    this.updateFileProgress(manifest.file_id, 100, "done")
    this.activeFileId = null
  }

  async uploadStatus(uploadId, files) {
    const response = await fetch("/upload_chunks/status", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Accept": "application/json",
        "X-CSRF-Token": this.csrfToken()
      },
      body: JSON.stringify({ upload_id: uploadId, files })
    })
    const body = await this.parseResponse(response)

    return body.files || {}
  }

  async completeUpload(uploadId, files) {
    const response = await fetch("/upload_chunks/complete", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Accept": "application/json",
        "X-CSRF-Token": this.csrfToken()
      },
      body: JSON.stringify({ upload_id: uploadId, files })
    })

    return this.parseResponse(response)
  }

  async postForm(url, formData) {
    const response = await fetch(url, {
      method: "POST",
      headers: {
        "Accept": "application/json",
        "X-CSRF-Token": this.csrfToken()
      },
      body: formData
    })

    return this.parseResponse(response)
  }

  async parseResponse(response) {
    const body = await response.json().catch(() => ({}))

    if (!response.ok) {
      throw new Error(body.error || "Upload failed.")
    }

    return body
  }

  setUploading(message) {
    this.submitTarget.value = "Uploading..."
    this.submitTarget.disabled = true
    this.summaryTarget.textContent = message
  }

  renderFileList(files) {
    this.fileListTarget.replaceChildren(...files.map((file, index) => this.fileRow(file, `file-${index}`)))
  }

  fileRow(file, fileId) {
    const row = document.createElement("li")
    row.className = "rounded-lg border border-zinc-200 bg-white p-3 text-left shadow-sm"
    row.dataset.fileId = fileId

    row.innerHTML = `
      <div class="flex items-center justify-between gap-3">
        <p class="min-w-0 truncate text-sm font-semibold text-zinc-950"></p>
        <p class="shrink-0 text-xs uppercase tracking-[0.12em] text-zinc-500" data-upload-status>pending</p>
      </div>
      <div class="mt-2 h-1 overflow-hidden rounded-full bg-zinc-200">
        <div class="h-full bg-teal-700 transition-all" style="width: 0%" data-upload-progress></div>
      </div>
      <p class="mt-2 text-xs text-zinc-500" data-upload-size></p>
    `

    row.querySelector("p").textContent = file.name
    row.querySelector("[data-upload-size]").textContent = this.humanSize(file.size)
    return row
  }

  updateFileProgress(fileId, percent, status) {
    const row = this.fileListTarget.querySelector(`[data-file-id="${CSS.escape(fileId)}"]`)
    if (!row) return

    row.querySelector("[data-upload-progress]").style.width = `${percent}%`
    row.querySelector("[data-upload-status]").textContent = status
  }

  markActiveFileFailed(message) {
    if (!this.activeFileId) return

    const row = this.fileListTarget.querySelector(`[data-file-id="${CSS.escape(this.activeFileId)}"]`)
    if (!row) return

    row.querySelector("[data-upload-status]").textContent = "failed"
    row.querySelector("[data-upload-size]").textContent = message
  }

  filePercent(completedChunks, totalChunks) {
    return Math.round((completedChunks / totalChunks) * 100)
  }

  humanSize(bytes) {
    const units = ["B", "KB", "MB", "GB"]
    let size = bytes
    let unitIndex = 0

    while (size >= 1024 && unitIndex < units.length - 1) {
      size /= 1024
      unitIndex += 1
    }

    return `${size.toFixed(unitIndex === 0 ? 0 : 1)} ${units[unitIndex]}`
  }

  uploadSession(files) {
    const fingerprint = this.fingerprint(files)
    const existing = this.storedUploadSession()

    if (existing?.fingerprint === fingerprint) {
      return existing
    }

    const session = {
      upload_id: crypto.randomUUID(),
      fingerprint,
      created_at: Date.now(),
      files: files.map((file, index) => ({
        file_id: `file-${index}`,
        filename: file.name,
        content_type: file.type,
        byte_size: file.size,
        last_modified: file.lastModified,
        total_chunks: Math.max(1, Math.ceil(file.size / CHUNK_SIZE))
      }))
    }

    localStorage.setItem(SESSION_KEY, JSON.stringify(session))
    return session
  }

  storedUploadSession() {
    const raw = localStorage.getItem(SESSION_KEY)
    if (!raw) return null

    try {
      const session = JSON.parse(raw)
      if (Date.now() - session.created_at > SESSION_TTL) {
        this.clearUploadSession()
        return null
      }

      return session
    } catch {
      this.clearUploadSession()
      return null
    }
  }

  clearUploadSession() {
    localStorage.removeItem(SESSION_KEY)
  }

  fingerprint(files) {
    return files.map((file) => [file.name, file.size, file.lastModified].join(":")).join("|")
  }

  async withRetries(callback) {
    let lastError

    for (let attempt = 1; attempt <= CHUNK_RETRIES; attempt += 1) {
      try {
        return await callback()
      } catch (error) {
        lastError = error
        if (attempt < CHUNK_RETRIES) await this.sleep(500 * attempt)
      }
    }

    throw lastError
  }

  sleep(milliseconds) {
    return new Promise((resolve) => setTimeout(resolve, milliseconds))
  }

  csrfToken() {
    return document.querySelector("meta[name='csrf-token']")?.content
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
