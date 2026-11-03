import { Controller } from "@hotwired/stimulus"
import { appendNextStreamPage } from "controllers/stream_page_loader"

let returnLinkUrl
let returnVisit

document.addEventListener("turbo:click", (event) => {
  if (!event.target.hasAttribute("data-directory-return")) return

  returnLinkUrl = event.detail.url
  // A canceled click must not affect a later visit to the same URL.
  queueMicrotask(() => { returnLinkUrl = undefined })
})

document.addEventListener("turbo:visit", ({ detail: { url, action } }) => {
  const fromBackLink = url === returnLinkUrl
  returnVisit = fromBackLink || action === "restore" ? { url, fromBackLink } : undefined
})

export default class extends Controller {
  static values = { viewer: String, kind: String }

  connect() {
    if (document.documentElement.hasAttribute("data-turbo-preview")) return
    if (returnVisit?.url !== window.location.href) return

    const { fromBackLink } = returnVisit
    returnVisit = undefined
    this.restore(fromBackLink)
  }

  remember(event) {
    const link = event.target.closest("a[data-directory-link]")
    if (!link || event.defaultPrevented || link.origin !== window.location.origin) return

    const card = link.closest(this.cardSelector)
    if (!card) return

    try {
      sessionStorage.setItem(this.storageKey, JSON.stringify({
        path: this.currentPath,
        entryId: history.state?.turbo?.restorationIdentifier,
        cardId: card.getAttribute(this.cardAttribute),
        offset: card.getBoundingClientRect().top,
        scrollY: window.scrollY,
        loadedCards: this.element.querySelectorAll(this.cardSelector).length,
        savedAt: Date.now()
      }))
    } catch {
      // Navigation still works when browser storage is unavailable.
    }
  }

  async restore(fromBackLink) {
    let state
    try {
      state = JSON.parse(sessionStorage.getItem(this.storageKey))
      if (!state || state.path !== this.currentPath) return
      if (!fromBackLink && (!state.entryId || state.entryId !== history.state?.turbo?.restorationIdentifier)) return
      sessionStorage.removeItem(this.storageKey)
    } catch {
      return
    }
    const cardId = state.cardId ?? state.locationId
    if (!Number.isFinite(state.savedAt) || Date.now() - state.savedAt > 86400000 || typeof cardId !== "string") return

    const selector = `[${this.cardAttribute}="${CSS.escape(cardId)}"]`
    const pageSize = Number(this.element.dataset.infiniteScrollPageSizeValue) || 12
    const maxPages = Math.min(100, Math.ceil(Number(state.loadedCards) / pageSize) + 1)
    this.element.style.visibility = "hidden"
    try {
      let card = this.element.querySelector(selector)
      for (let page = 0; !card && page < maxPages; page++) {
        const sentinel = this.element.querySelector("[data-infinite-scroll-target='sentinel']")
        if (!sentinel?.dataset.nextUrl || !await appendNextStreamPage(sentinel)) break
        card = this.element.querySelector(selector)
      }
      if (!this.element.isConnected) return

      await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)))
      if (!this.element.isConnected) return

      const top = card && Number.isFinite(state.offset)
        ? window.scrollY + card.getBoundingClientRect().top - state.offset
        : Number(state.scrollY)
      if (Number.isFinite(top)) window.scrollTo({ top: Math.max(0, top), left: 0, behavior: "instant" })
    } catch {
      // Keep the usable directory visible if restoration cannot fetch a page.
    } finally {
      this.element.style.visibility = ""
    }
  }

  get currentPath() {
    return `${window.location.pathname}${window.location.search}`
  }

  get storageKey() {
    return `photos.${this.kindValue}sState.${this.viewerValue}.${this.currentPath}`
  }

  get cardAttribute() {
    return `data-${this.kindValue}-id`
  }

  get cardSelector() {
    return `[${this.cardAttribute}]`
  }
}
