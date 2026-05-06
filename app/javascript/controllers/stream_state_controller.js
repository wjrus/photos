import { Controller } from "@hotwired/stimulus"
import { appendNextStreamPage } from "controllers/stream_page_loader"

export default class extends Controller {
  static values = {
    targetPhotoId: String
  }

  connect() {
    if ("scrollRestoration" in window.history) {
      window.history.scrollRestoration = "manual"
    }

    this.restore()
  }

  save(event) {
    const link = event.target.closest("a")
    if (!link) return
    if (!link.pathname.startsWith("/photos/")) return

    this.storeReturnTo(link.dataset.photoReturnTo || this.currentPath)
    sessionStorage.setItem(this.storageKey, JSON.stringify({
      path: this.currentPath,
      scrollY: window.scrollY,
      savedAt: Date.now()
    }))
  }

  storeReturnTo(path) {
    if (!path?.startsWith("/")) return

    document.cookie = [
      `photos_return_to=${encodeURIComponent(path)}`,
      "path=/",
      "max-age=86400",
      "samesite=lax"
    ].join("; ")
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
