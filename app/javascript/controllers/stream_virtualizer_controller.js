import { Controller } from "@hotwired/stimulus"

const BUFFER_VIEWPORTS = 4

export default class extends Controller {
  connect() {
    this.cache = new Map()
    this.update = this.update.bind(this)
    this.scheduleUpdate = this.scheduleUpdate.bind(this)

    this.mutationObserver = new MutationObserver(this.scheduleUpdate)
    this.mutationObserver.observe(this.element, { childList: true })
    window.addEventListener("scroll", this.scheduleUpdate, { passive: true })
    window.addEventListener("resize", this.scheduleUpdate, { passive: true })
    this.scheduleUpdate()
  }

  disconnect() {
    this.mutationObserver?.disconnect()
    window.removeEventListener("scroll", this.scheduleUpdate)
    window.removeEventListener("resize", this.scheduleUpdate)
    cancelAnimationFrame(this.frame)
  }

  scheduleUpdate() {
    if (this.frame) return
    this.frame = requestAnimationFrame(this.update)
  }

  update() {
    this.frame = null
    const viewportHeight = window.innerHeight || document.documentElement.clientHeight
    const buffer = viewportHeight * BUFFER_VIEWPORTS

    this.groups().forEach((group) => {
      const rect = group.getBoundingClientRect()
      const nearby = rect.bottom >= -buffer && rect.top <= viewportHeight + buffer

      if (nearby) {
        this.restore(group)
      } else {
        this.collapse(group)
      }
    })
  }

  groups() {
    return Array.from(this.element.querySelectorAll("[data-stream-date-group-key]"))
  }

  collapse(group) {
    if (group.dataset.streamVirtualized === "true") return
    if (group.matches(":focus-within")) return
    if (group.querySelector("input:checked")) return

    const height = Math.max(group.getBoundingClientRect().height, 1)
    this.cache.set(group.id, group.innerHTML)
    group.dataset.streamVirtualized = "true"
    group.style.height = `${height}px`
    group.innerHTML = `<div class="flex h-full items-center text-xs font-semibold uppercase tracking-[0.18em] text-zinc-400">Photos unloaded while offscreen</div>`
  }

  restore(group) {
    if (group.dataset.streamVirtualized !== "true") return

    const html = this.cache.get(group.id)
    if (!html) return

    group.innerHTML = html
    group.style.height = ""
    delete group.dataset.streamVirtualized
    this.cache.delete(group.id)
  }
}
