import { Controller } from "@hotwired/stimulus"
import { streamPageHtml } from "controllers/stream_page_loader"

export default class extends Controller {
  static targets = ["item", "label", "rail", "thumb"]

  connect() {
    this.dragging = false
    this.loadingUrl = null
    this.updateActiveItem = this.updateActiveItem.bind(this)
    window.addEventListener("scroll", this.updateActiveItem, { passive: true })
    this.updateActiveItem()
  }

  disconnect() {
    window.removeEventListener("scroll", this.updateActiveItem)
    this.abortController?.abort()
  }

  pointerdown(event) {
    this.dragging = true
    this.element.setPointerCapture?.(event.pointerId)
    this.activateNearestItem(event.clientY)
  }

  pointermove(event) {
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

    this.hideLabel()
    this.clearHoverItems()
    this.updateActiveItem()
  }

  jump(event) {
    event.preventDefault()
    this.scrollToPeriod(event.currentTarget)
  }

  activateNearestItem(clientY) {
    if (!this.hasItemTarget) return null

    const item = this.nearestItem(clientY)
    if (!item) return null

    this.clearHoverItems()
    item.classList.add("text-teal-700")
    this.moveThumbToItem(item)
    this.showLabel(item)
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
  }

  nearestItem(clientY) {
    return this.itemTargets.reduce((nearest, item) => {
      const distance = Math.abs(item.getBoundingClientRect().top - clientY)
      if (!nearest || distance < nearest.distance) return { item, distance }
      return nearest
    }, null)?.item
  }

  showLabel(item) {
    if (!this.hasLabelTarget || !this.hasRailTarget) return

    const itemRect = item.getBoundingClientRect()
    const railRect = this.railTarget.getBoundingClientRect()
    const top = itemRect.top - railRect.top
    const count = item.dataset.streamTimelineCountValue

    this.labelTarget.textContent = [item.dataset.streamTimelineLabelValue, count].filter(Boolean).join(" · ")
    this.labelTarget.style.top = `${top}px`
    this.labelTarget.classList.remove("hidden")
  }

  hideLabel() {
    if (this.hasLabelTarget) this.labelTarget.classList.add("hidden")
  }

  updateActiveItem() {
    const group = this.currentDateGroup()
    if (!group) return

    const periodKey = group.dataset.streamDateGroupKey.slice(0, 7)
    this.setActivePeriod(periodKey)
    this.moveThumbToPeriod(periodKey)
  }

  currentDateGroup() {
    const groups = Array.from(document.querySelectorAll("[data-stream-date-group-key]"))
    return groups.find((group) => group.getBoundingClientRect().bottom > 120) || groups.at(-1)
  }

  findPeriodGroup(periodKey) {
    return Array.from(document.querySelectorAll("[data-stream-date-group-key]"))
      .find((group) => group.dataset.streamDateGroupKey.startsWith(periodKey))
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
    this.itemTargets.forEach((item) => {
      const active = item.dataset.streamTimelinePeriodKeyValue === periodKey
      item.classList.toggle("text-zinc-950", active)
      item.classList.toggle("font-bold", active)
      item.classList.toggle("stream-timeline__item--active", active)
      item.setAttribute("aria-current", active ? "date" : "false")
    })
  }

  clearHoverItems() {
    this.itemTargets.forEach((item) => item.classList.remove("text-teal-700"))
  }

  moveThumbToPeriod(periodKey) {
    const item = this.itemTargets.find((target) => target.dataset.streamTimelinePeriodKeyValue === periodKey)
    if (item) this.moveThumbToItem(item)
  }

  moveThumbToItem(item) {
    if (!this.hasThumbTarget || !this.hasRailTarget) return

    const itemRect = item.getBoundingClientRect()
    const railRect = this.railTarget.getBoundingClientRect()
    const progress = (itemRect.top - railRect.top) / railRect.height
    this.thumbTarget.style.top = `${Math.min(Math.max(progress, 0), 1) * 100}%`
  }
}
