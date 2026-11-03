import { Controller } from "@hotwired/stimulus"
import { appendNextStreamPage } from "controllers/stream_page_loader"

export default class extends Controller {
  static values = {
    targetPhotoId: String
  }

  connect() {
    this.openingEvents = new AbortController()
    const { signal } = this.openingEvents
    document.addEventListener("turbo:before-render", () => this.clearOpeningStatus(), { signal })
    document.addEventListener("turbo:fetch-request-error", () => this.clearOpeningStatus(), { signal })

    if ("scrollRestoration" in window.history) {
      window.history.scrollRestoration = "manual"
    }

    this.restore()
  }

  disconnect() {
    this.openingEvents.abort()
    this.clearOpeningStatus()
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
    this.showOpeningStatus(link.closest("[data-photo-id]"))
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

  showOpeningStatus(card) {
    if (!card) return

    this.clearOpeningStatus()
    const status = document.createElement("p")
    status.className = "photo-opening-status"
    status.dataset.turboTemporary = ""
    status.setAttribute("role", "status")
    status.textContent = "Opening photo…"
    card.append(status)
    this.openingStatus = status
    this.openingTimeout = setTimeout(() => this.clearOpeningStatus(), 15000)
  }

  clearOpeningStatus() {
    clearTimeout(this.openingTimeout)
    this.openingStatus?.remove()
    this.openingStatus = null
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
