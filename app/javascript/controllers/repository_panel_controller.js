import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["content", "status", "retry"]
  static values = { url: String, interval: { type: Number, default: 60 } }

  connect() {
    this.connected = true
    this.visible = false
    this.failures = 0
    this.nextRefreshAt = 0
    this.interactionRevision = 0
    this.dirty = this.contentTarget.dataset.repositoryPanelDirty === "true"
    this.lastVersion = this.contentTarget.dataset.repositoryPanelVersion || null
    const generatedAt = this.contentTarget.dataset.repositoryPanelGeneratedAt
    this.lastGeneratedAt = generatedAt ? new Date(generatedAt) : null
    this.deferredPayload = null
    this.accessExpired = false
    this.boundVisibility = this.visibilityChanged.bind(this)
    this.boundSuspend = this.suspend.bind(this)
    this.boundInteraction = this.interactionChanged.bind(this)
    document.addEventListener("visibilitychange", this.boundVisibility)
    document.addEventListener("turbo:before-cache", this.boundSuspend)
    document.addEventListener("turbo:before-visit", this.boundSuspend)
    for (const event of ["input", "change", "focusin", "focusout", "toggle"]) {
      this.contentTarget.addEventListener(event, this.boundInteraction, true)
    }

    this.observer = new IntersectionObserver(entries => {
      this.visible = entries.at(-1).isIntersecting
      this.visibilityChanged()
    }, { rootMargin: "200px 0px" })
    this.observer.observe(this.element)
  }

  disconnect() {
    this.connected = false
    this.suspend()
    this.observer.disconnect()
    document.removeEventListener("visibilitychange", this.boundVisibility)
    document.removeEventListener("turbo:before-cache", this.boundSuspend)
    document.removeEventListener("turbo:before-visit", this.boundSuspend)
    for (const event of ["input", "change", "focusin", "focusout", "toggle"]) {
      this.contentTarget.removeEventListener(event, this.boundInteraction, true)
    }
  }

  refresh(event) {
    event?.preventDefault()
    this.accessExpired = false
    this.load(true)
  }

  visibilityChanged() {
    if (!this.active) {
      this.suspend()
      return
    }

    this.applyDeferredPayload()
    this.schedule()
  }

  suspend() {
    clearTimeout(this.timer)
    const wasUpdating = this.requestController
    this.requestController?.abort()
    this.requestController = null
    this.contentTarget.setAttribute("aria-busy", "false")
    if (wasUpdating) this.setStatus(this.lastGeneratedAt ? this.updatedText : "Waiting to load…")
  }

  get active() {
    return this.connected && this.visible && !document.hidden
  }

  schedule() {
    clearTimeout(this.timer)
    if (!this.active || this.requestController || this.accessExpired) return

    this.timer = setTimeout(() => this.load(), Math.max(0, this.nextRefreshAt - Date.now()))
  }

  async load(manual = false) {
    if (!this.active || this.requestController || this.accessExpired) return

    clearTimeout(this.timer)
    const request = new AbortController()
    const interactionRevision = this.interactionRevision
    this.requestController = request
    this.contentTarget.setAttribute("aria-busy", "true")
    this.setStatus(this.lastGeneratedAt ? `Updating · ${this.updatedText}` : "Loading…")

    try {
      const url = new URL(this.urlValue, window.location.href)
      if (url.origin !== window.location.origin) throw new Error("Invalid panel URL")
      if (manual) url.searchParams.set("refresh", "1")
      const response = await fetch(url, {
        headers: { Accept: "application/json" },
        credentials: "same-origin",
        cache: "no-store",
        redirect: "error",
        signal: request.signal
      })
      if (this.requestController !== request || !this.active) return
      if (response.status === 401 || response.status === 403) {
        this.accessExpired = true
        this.contentTarget.replaceChildren()
        delete this.contentTarget.dataset.repositoryPanelVersion
        delete this.contentTarget.dataset.repositoryPanelGeneratedAt
        delete this.contentTarget.dataset.repositoryPanelDirty
        this.lastVersion = null
        this.lastGeneratedAt = null
        this.deferredPayload = null
        this.dirty = false
        throw new Error("Access expired")
      }
      if (!response.ok || response.redirected || !response.headers.get("content-type")?.includes("application/json")) {
        throw new Error("Invalid panel response")
      }

      const payload = await response.json()
      if (typeof payload.html !== "string" || !Number.isFinite(Date.parse(payload.generated_at))) {
        throw new Error("Invalid panel data")
      }
      if (this.requestController !== request || !this.active) return

      this.failures = 0
      this.nextRefreshAt = Date.now() + this.intervalMilliseconds(payload.refresh_after)
      const unchanged = this.payloadVersion(payload) === this.lastVersion
      const deliberateRefresh = manual && interactionRevision === this.interactionRevision && !this.focusedControl && !this.openDialog
      if (unchanged || deliberateRefresh || !this.interacting) {
        this.render(payload)
      } else {
        this.deferredPayload = payload
        this.setStatus(`Update ready · ${this.updatedText}. Refresh when finished.`)
      }
    } catch (error) {
      if (this.requestController !== request || error.name === "AbortError") return

      this.failures += 1
      this.nextRefreshAt = Date.now() + Math.min(300000, this.intervalMilliseconds() * (2 ** Math.min(this.failures - 1, 6)))
      if (this.accessExpired) {
        this.setStatus("Access expired. Reload the page to sign in.")
      } else {
        this.setStatus(this.lastGeneratedAt ? `Update failed · ${this.updatedText}. Retry available.` : "Couldn’t load this section. Retry available.")
      }
    } finally {
      if (this.requestController === request) {
        this.requestController = null
        this.contentTarget.setAttribute("aria-busy", "false")
        if (this.hasRetryTarget) this.retryTarget.textContent = this.failures ? "Retry" : "Refresh"
        this.schedule()
      }
    }
  }

  intervalMilliseconds(seconds = this.intervalValue) {
    const interval = Number(seconds)
    return Math.max(1, Math.min(3600, Number.isFinite(interval) && interval > 0 ? interval : 60)) * 1000
  }

  payloadVersion(payload) {
    return payload.version || payload.html
  }

  render(payload) {
    if (this.payloadVersion(payload) !== this.lastVersion) {
      // Only the authenticated same-origin JSON endpoint supplies this Rails-rendered,
      // escaped HTML. Redirects and non-JSON responses never reach this boundary.
      const template = document.createElement("template")
      template.innerHTML = payload.html
      this.contentTarget.replaceChildren(template.content)
      this.lastVersion = this.payloadVersion(payload)
      if (payload.version) this.contentTarget.dataset.repositoryPanelVersion = payload.version
      this.dirty = false
      delete this.contentTarget.dataset.repositoryPanelDirty
    }
    this.lastGeneratedAt = new Date(payload.generated_at)
    this.contentTarget.dataset.repositoryPanelGeneratedAt = payload.generated_at
    this.deferredPayload = null
    this.setStatus(this.updatedText)
    this.dispatch("updated", { detail: { generatedAt: payload.generated_at } })
  }

  interactionChanged(event) {
    this.interactionRevision += 1
    if (event.type === "input" || event.type === "change") {
      this.dirty = true
      this.contentTarget.dataset.repositoryPanelDirty = "true"
    }
    queueMicrotask(() => this.applyDeferredPayload())
  }

  applyDeferredPayload() {
    if (this.active && this.deferredPayload && !this.interacting) this.render(this.deferredPayload)
  }

  get interacting() {
    return this.dirty || this.focusedControl || this.openDialog || this.contentTarget.querySelector("details[open]")
  }

  get focusedControl() {
    const focused = document.activeElement
    return this.contentTarget.contains(focused) && focused.matches("a, button, input, select, textarea, summary, [tabindex], [contenteditable]")
  }

  get openDialog() {
    // Confirmation dialogs can be moved to document.body by their own controller.
    return document.querySelector('dialog[open], [role="dialog"]:not(.hidden)')
  }

  get updatedText() {
    if (!this.lastGeneratedAt) return "Waiting to update"
    return `Last updated ${this.lastGeneratedAt.toLocaleTimeString([], { hour: "numeric", minute: "2-digit", second: "2-digit" })}`
  }

  setStatus(text) {
    if (this.hasStatusTarget) this.statusTarget.textContent = text
  }
}
