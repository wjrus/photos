import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["progress"]

  connect() {
    this.duration = 6000
    this.startedAt = performance.now()
    this.animationFrame = requestAnimationFrame(this.tick.bind(this))
  }

  disconnect() {
    cancelAnimationFrame(this.animationFrame)
  }

  dismiss() {
    this.element.remove()
  }

  tick(now) {
    const elapsed = now - this.startedAt
    const remaining = Math.max(0, 1 - elapsed / this.duration)

    this.progressTarget.style.transform = `scaleX(${remaining})`
    this.progressTarget.style.transformOrigin = "left center"

    if (remaining <= 0) {
      this.dismiss()
      return
    }

    this.animationFrame = requestAnimationFrame(this.tick.bind(this))
  }
}
