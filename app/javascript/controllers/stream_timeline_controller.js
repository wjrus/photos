import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["item", "label", "rail"]

  connect() {
    this.dragging = false
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
    if (item) window.location.assign(item.href)
  }

  pointerleave() {
    if (this.dragging) return

    this.hideLabel()
    this.clearActiveItems()
  }

  activateNearestItem(clientY) {
    if (!this.hasItemTarget) return null

    const item = this.nearestItem(clientY)
    if (!item) return null

    this.clearActiveItems()
    item.classList.add("text-zinc-950")
    this.showLabel(item)
    return item
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

  clearActiveItems() {
    this.itemTargets.forEach((item) => item.classList.remove("text-zinc-950"))
  }
}
