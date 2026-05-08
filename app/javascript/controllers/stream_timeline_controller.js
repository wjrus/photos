import { Controller } from "@hotwired/stimulus"
import { streamPageHtml } from "controllers/stream_page_loader"

export default class extends Controller {
  static targets = ["item", "label", "rail", "thumb"]
  static values = {
    precision: { type: String, default: "month" }
  }

  connect() {
    this.dragging = false
    this.hovering = false
    this.loadingUrl = null
    this.updateActiveItem = this.updateActiveItem.bind(this)
    window.addEventListener("scroll", this.updateActiveItem, { passive: true })
    document.addEventListener("photos:stream-page-loaded", this.updateActiveItem)
    this.updateActiveItem()
  }

  disconnect() {
    window.removeEventListener("scroll", this.updateActiveItem)
    document.removeEventListener("photos:stream-page-loaded", this.updateActiveItem)
    this.abortController?.abort()
  }

  pointerdown(event) {
    event.preventDefault()
    this.dragging = true
    this.hovering = true
    this.element.setPointerCapture?.(event.pointerId)
    this.activateNearestItem(event.clientY)
  }

  pointermove(event) {
    this.hovering = true
    this.activateNearestItem(event.clientY)
  }

  pointerup(event) {
    if (!this.dragging) return

    this.dragging = false
    this.element.releasePointerCapture?.(event.pointerId)
    const item = this.activateNearestItem(event.clientY)
    if (item) this.scrollToPeriod(item)
  }

  pointerleave() {
    if (this.dragging) return

    this.hovering = false
    this.clearHoverItems()
    this.updateActiveItem()
  }

  jump(event) {
    event.preventDefault()
    this.hovering = false
    this.scrollToPeriod(event.currentTarget)
  }

  activateNearestItem(clientY) {
    if (!this.hasItemTarget) return null

    const item = this.nearestItem(clientY)
    if (!item) return null

    this.clearHoverItems()
    item.classList.add("text-teal-700")
    this.moveThumbToItem(item)
    this.showLabel(item, clientY)
    return item
  }

  async scrollToPeriod(item) {
    const periodKey = item.dataset.streamTimelinePeriodKeyValue
    let group = this.findPeriodGroup(periodKey)

    if (!group) {
      await this.loadPeriodPage(item)
      group = this.findPeriodGroup(periodKey)
    }

    group?.scrollIntoView({ block: "start", behavior: "smooth" })
    this.setActivePeriod(periodKey)
    this.moveThumbToPeriod(periodKey)
    this.showActiveLabel(periodKey)
  }

  nearestItem(clientY) {
    return this.itemTargets.reduce((nearest, item) => {
      const distance = Math.abs(item.getBoundingClientRect().top - clientY)
      if (!nearest || distance < nearest.distance) return { item, distance }
      return nearest
    }, null)?.item
  }

  showLabel(item, clientY = null) {
    if (!this.hasLabelTarget || !this.hasRailTarget) return

    const itemRect = item.getBoundingClientRect()
    const railRect = this.railTarget.getBoundingClientRect()
    const rawTop = clientY == null ? itemRect.top - railRect.top : clientY - railRect.top
    const top = Math.min(Math.max(rawTop, 16), Math.max(railRect.height - 16, 16))
    const count = item.dataset.streamTimelineCountValue

    this.labelTarget.textContent = [item.dataset.streamTimelineLabelValue, count].filter(Boolean).join(" · ")
    this.labelTarget.style.top = `${top}px`
    this.labelTarget.classList.remove("hidden")
  }

  hideLabel() {
    if (this.hasLabelTarget) this.labelTarget.classList.add("hidden")
  }

  updateActiveItem() {
    const element = this.currentPeriodElement()
    if (!element) {
      if (!this.hovering && !this.dragging) this.hideLabel()
      return
    }

    const periodKey = this.periodKeyForElement(element)
    const item = this.setActivePeriod(periodKey)
    this.moveThumbToPeriod(periodKey)

    if (!this.hovering && !this.dragging && item) this.showLabel(item)
  }

  currentPeriodElement() {
    const elements = this.loadedPeriodElements()
    return elements.find((element) => element.getBoundingClientRect().bottom > 120) || elements.at(-1)
  }

  loadedPeriodElements() {
    if (this.precisionValue === "hour") {
      const loadedCards = Array.from(document.querySelectorAll("[data-stream-timeline-hour-key]:not([data-stream-virtualized='true'])"))
      if (loadedCards.length > 0) return loadedCards

      return Array.from(document.querySelectorAll("[data-stream-timeline-hour-key]"))
    }

    return this.loadedDateGroups()
  }

  loadedDateGroups() {
    const loadedGroups = Array.from(document.querySelectorAll("[data-stream-date-group-key]:not([data-stream-virtualized='true'])"))
    if (loadedGroups.length > 0) return loadedGroups

    return Array.from(document.querySelectorAll("[data-stream-date-group-key]"))
  }

  findPeriodGroup(periodKey) {
    return Array.from(document.querySelectorAll(`[${this.periodDataAttribute}]`))
      .find((group) => group.dataset[this.periodDatasetKey] === periodKey) ||
      Array.from(document.querySelectorAll("[data-stream-date-group-key]"))
        .find((group) => periodKey.startsWith(group.dataset.streamDateGroupKey))
  }

  async loadPeriodPage(item) {
    const url = item.dataset.streamTimelinePageUrlValue
    const container = document.querySelector("[data-stream-page-container]")
    if (!url || !container) return
    if (this.loadingUrl === url) return

    this.abortController?.abort()
    this.abortController = new AbortController()
    this.loadingUrl = url
    container.setAttribute("aria-busy", "true")

    this.labelTarget.textContent = "Loading..."
    this.labelTarget.classList.remove("hidden")

    try {
      const response = await fetch(url, {
        headers: { "Accept": "text/html" },
        signal: this.abortController.signal
      })
      if (!response.ok) throw new Error(`Timeline jump failed with ${response.status}`)

      container.innerHTML = streamPageHtml(await response.text())
      document.dispatchEvent(new CustomEvent("photos:stream-page-loaded"))
    } catch (error) {
      if (error.name !== "AbortError") {
        console.error(error)
        this.labelTarget.textContent = "Could not load"
      }
    } finally {
      container.removeAttribute("aria-busy")
      this.loadingUrl = null
    }
  }

  setActivePeriod(periodKey) {
    let activeItem = null

    this.itemTargets.forEach((item) => {
      const active = item.dataset.streamTimelinePeriodKeyValue === periodKey
      item.classList.toggle("text-zinc-950", active)
      item.classList.toggle("font-bold", active)
      item.classList.toggle("stream-timeline__item--active", active)
      item.setAttribute("aria-current", active ? "date" : "false")
      if (active) activeItem = item
    })

    return activeItem
  }

  clearHoverItems() {
    this.itemTargets.forEach((item) => item.classList.remove("text-teal-700"))
  }

  moveThumbToPeriod(periodKey) {
    const item = this.itemTargets.find((target) => target.dataset.streamTimelinePeriodKeyValue === periodKey)
    if (item) this.moveThumbToItem(item)
  }

  showActiveLabel(periodKey) {
    const item = this.itemTargets.find((target) => target.dataset.streamTimelinePeriodKeyValue === periodKey)
    if (item) this.showLabel(item)
  }

  moveThumbToItem(item) {
    if (!this.hasThumbTarget || !this.hasRailTarget) return

    const itemRect = item.getBoundingClientRect()
    const railRect = this.railTarget.getBoundingClientRect()
    const progress = (itemRect.top - railRect.top) / railRect.height
    this.thumbTarget.style.top = `${Math.min(Math.max(progress, 0), 1) * 100}%`
  }

  periodKeyForElement(element) {
    const dateGroupKey = element.dataset.streamDateGroupKey
    const fallbackKey = this.precisionValue === "month" ? dateGroupKey?.slice(0, 7) : dateGroupKey

    return element.dataset[this.periodDatasetKey] || fallbackKey
  }

  get periodDataAttribute() {
    return `data-stream-timeline-${this.precisionValue}-key`
  }

  get periodDatasetKey() {
    return `streamTimeline${this.precisionValue[0].toUpperCase()}${this.precisionValue.slice(1)}Key`
  }
}
