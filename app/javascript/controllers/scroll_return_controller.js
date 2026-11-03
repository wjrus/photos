import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["original", "tab"]

  connect() {
    const header = this.tabTarget.closest("header")
    this.resizeObserver = new ResizeObserver(() => {
      // The bulk toolbar can change how much of the page the sticky header covers.
      const headerHeight = Math.ceil(header.getBoundingClientRect().height)
      this.linkObserver?.disconnect()
      this.linkObserver = new IntersectionObserver(([entry]) => {
        this.tabTarget.hidden = entry.isIntersecting || entry.boundingClientRect.bottom > headerHeight
      }, { rootMargin: `-${headerHeight}px 0px 0px 0px` })
      this.linkObserver.observe(this.originalTarget)
    })
    this.resizeObserver.observe(header)
  }

  disconnect() {
    this.resizeObserver.disconnect()
    this.linkObserver?.disconnect()
  }

  hide() {
    this.tabTarget.hidden = true
  }
}
