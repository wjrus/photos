import { Controller } from "@hotwired/stimulus"
import { appendNextStreamPage } from "controllers/stream_page_loader"

export default class extends Controller {
  connect() {
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
    const state = this.storedState
    if (!state || state.path !== this.currentPath) return

    const targetY = Number(state.scrollY)
    if (!Number.isFinite(targetY) || targetY <= 0) return

    await this.loadUntilReachable(targetY)
    requestAnimationFrame(() => window.scrollTo({ top: targetY, left: 0, behavior: "instant" }))
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

  get storageKey() {
    return "photos.streamState"
  }
}
