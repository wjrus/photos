import { Controller } from "@hotwired/stimulus"
import { appendNextStreamPage } from "controllers/stream_page_loader"

export default class extends Controller {
  static values = {
    targetPhotoId: String
  }

  connect() {
    this.previewEvents = new AbortController()
    const { signal } = this.previewEvents
    document.addEventListener("turbo:before-render", (event) => this.finishOpeningPreview(event), { signal })
    document.addEventListener("turbo:fetch-request-error", () => this.clearOpeningPreview(), { signal })

    if ("scrollRestoration" in window.history) {
      window.history.scrollRestoration = "manual"
    }

    this.restore()
  }

  disconnect() {
    this.previewEvents.abort()
    this.clearOpeningPreview()
  }

  save(event) {
    const link = event.target.closest("a")
    if (!link) return
    if (!link.pathname.startsWith("/photos/")) return
    if (event.defaultPrevented) return

    const returnTo = link.dataset.photoReturnTo || this.currentPath
    const storedReturnTo = this.storeReturnTo(returnTo)
    try {
      sessionStorage.setItem(this.storageKey, JSON.stringify({
        path: this.currentPath,
        scrollY: window.scrollY,
        savedAt: Date.now()
      }))
    } catch {
      // The server can still return to the focused photo without saved scroll state.
    }

    if (!this.shouldNavigateWithReturnTo(event, link)) return

    event.preventDefault()
    this.showOpeningPreview(link.closest("[data-photo-id]"))
    this.visitWithReturnTo(link.href, storedReturnTo ? null : returnTo)
  }

  storeReturnTo(path) {
    if (!path?.startsWith("/")) return

    const cookie = `photos_return_to=${encodeURIComponent(path)}`
    document.cookie = `${cookie}; path=/; max-age=86400; samesite=lax${location.protocol === "https:" ? "; secure" : ""}`
    // Keep the server's return-path redirect as a fallback if the browser rejects the cookie.
    return document.cookie.split(/;\s*/).includes(cookie)
  }

  shouldNavigateWithReturnTo(event, link) {
    return event.button === 0 &&
      !event.metaKey &&
      !event.ctrlKey &&
      !event.shiftKey &&
      !event.altKey &&
      !link.target &&
      !link.hasAttribute("download")
  }

  visitWithReturnTo(href, returnTo) {
    const url = new URL(href, window.location.origin)
    if (returnTo) url.searchParams.set("return_to", returnTo)
    const path = `${url.pathname}${url.search}${url.hash}`

    if (window.Turbo) {
      window.Turbo.visit(path)
    } else {
      window.location.href = path
    }
  }

  showOpeningPreview(card) {
    if (!card) return

    this.clearOpeningPreview()
    const preview = document.createElement("div")
    preview.className = "photo-opening-preview"
    preview.dataset.turboTemporary = ""
    preview.dataset.openingPhotoId = card.dataset.photoId

    const image = card.querySelector("img[data-thumbnail-preload-target='image']")
    if (image?.complete && image.naturalWidth > 0) {
      const canvas = document.createElement("canvas")
      canvas.width = image.naturalWidth
      canvas.height = image.naturalHeight
      canvas.className = "photo-opening-image"
      canvas.dataset.turboTemporary = ""
      canvas.setAttribute("aria-hidden", "true")
      const context = canvas.getContext("2d")
      if (context) {
        context.drawImage(image, 0, 0)
        preview.append(canvas)
      }
    }

    const status = document.createElement("p")
    status.setAttribute("role", "status")
    status.textContent = "Opening photo…"
    preview.append(status)
    document.body.append(preview)
    this.openingPreview = preview
    this.previewTimeout = setTimeout(() => this.clearOpeningPreview(), 15000)
  }

  finishOpeningPreview(event) {
    if (!this.openingPreview) return

    const canvas = this.openingPreview.querySelector("canvas")
    const viewer = event.detail.newBody.querySelector("[data-photo-viewer-id]")
    const image = viewer?.querySelector("img.photo-detail-media")
    if (canvas && viewer?.dataset.photoViewerId === this.openingPreview.dataset.openingPhotoId && image && !image.complete) {
      viewer.append(canvas)
      image.addEventListener("load", () => canvas.remove(), { once: true })
      image.addEventListener("error", () => canvas.remove(), { once: true })
    }

    this.clearOpeningPreview()
  }

  clearOpeningPreview() {
    clearTimeout(this.previewTimeout)
    this.openingPreview?.remove()
    this.openingPreview = null
  }

  async restore() {
    if (this.navigationType === "reload") {
      this.clearStoredState()
      window.scrollTo({ top: 0, left: 0, behavior: "auto" })
      return
    }

    const state = this.storedState
    if (!state || state.path !== this.currentPath) {
      await this.scrollToTargetPhoto()
      return
    }

    const targetY = Number(state.scrollY)
    this.clearStoredState()
    if (!Number.isFinite(targetY) || targetY <= 0) return

    this.hideWhileRestoring()
    await this.loadUntilReachable(targetY)
    requestAnimationFrame(() => {
      window.scrollTo({ top: targetY, left: 0, behavior: "auto" })
      this.showAfterRestoring()
    })
  }

  async loadUntilReachable(targetY) {
    while (document.documentElement.scrollHeight < targetY + window.innerHeight) {
      const sentinel = this.element.querySelector("[data-infinite-scroll-target='sentinel']")
      if (!sentinel?.dataset.nextUrl) return

      try {
        await appendNextStreamPage(sentinel, "Restoring...")
      } catch {
        return
      }
    }
  }

  async scrollToTargetPhoto() {
    if (!this.targetPhotoIdValue) return

    this.hideWhileRestoring()

    let target = this.targetPhoto
    while (!target) {
      const sentinel = this.element.querySelector("[data-infinite-scroll-target='sentinel']:not([data-stream-page-direction='newer'])")
      if (!sentinel?.dataset.nextUrl) break

      try {
        await appendNextStreamPage(sentinel, "Loading...")
      } catch {
        break
      }

      target = this.targetPhoto
    }

    requestAnimationFrame(() => {
      target?.scrollIntoView({ block: "center", behavior: "auto" })
      this.showAfterRestoring()
    })
  }

  hideWhileRestoring() {
    this.element.style.visibility = "hidden"
  }

  showAfterRestoring() {
    this.element.style.visibility = ""
  }

  clearStoredState() {
    sessionStorage.removeItem(this.storageKey)
  }

  get storedState() {
    try {
      return JSON.parse(sessionStorage.getItem(this.storageKey))
    } catch {
      return null
    }
  }

  get currentPath() {
    return `${window.location.pathname}${window.location.search}`
  }

  get targetPhoto() {
    return this.element.querySelector(`[data-photo-id='${CSS.escape(this.targetPhotoIdValue)}']`)
  }

  get navigationType() {
    return performance.getEntriesByType("navigation")[0]?.type
  }

  get storageKey() {
    return "photos.streamState"
  }
}
