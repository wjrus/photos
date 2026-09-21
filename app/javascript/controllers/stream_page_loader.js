const pendingPages = new WeakMap()

export async function appendNextStreamPage(sentinel, loadingLabel = "Loading...") {
  return loadStreamPage(sentinel, loadingLabel, "append")
}

export async function prependPreviousStreamPage(sentinel, loadingLabel = "Loading...") {
  return loadStreamPage(sentinel, loadingLabel, "prepend")
}

async function loadStreamPage(sentinel, loadingLabel, direction) {
  const url = sentinel?.dataset.nextUrl
  if (!url || !sentinel.isConnected) return false
  if (pendingPages.has(sentinel)) return pendingPages.get(sentinel)

  // Scroll restoration and infinite scrolling can ask for the same page together.
  const pending = fetchStreamPage(sentinel, url, loadingLabel, direction)
  pendingPages.set(sentinel, pending)
  try {
    return await pending
  } finally {
    pendingPages.delete(sentinel)
  }
}

async function fetchStreamPage(sentinel, url, loadingLabel, direction) {
  const controller = new AbortController()
  const timeout = setTimeout(() => controller.abort(), 30000)

  sentinel.textContent = loadingLabel
  try {
    const response = await fetch(url, {
      headers: { "Accept": "text/html" },
      signal: controller.signal
    })
    if (!response.ok) throw new Error("Could not load more photos.")

    const html = streamPageHtml(await response.text()).trim()
    if (!sentinel.isConnected) return false
    if (!html) {
      sentinel.textContent = "No more photos."
      delete sentinel.dataset.nextUrl
      return false
    }

    const anchor = visibleStreamAnchor(sentinel.closest("[data-stream-page-container]"))
    insertStreamPage(sentinel, html, direction)
    sentinel.remove()
    restoreStreamAnchor(anchor)
    document.dispatchEvent(new CustomEvent("photos:stream-page-loaded"))
    return true
  } finally {
    clearTimeout(timeout)
  }
}

function visibleStreamAnchor(container) {
  if (!container) return

  for (const element of container.querySelectorAll("[data-photo-id], article")) {
    const rect = element.getBoundingClientRect()
    if (rect.bottom > 0 && rect.top < window.innerHeight) return { element, top: rect.top }
  }
}

function restoreStreamAnchor(anchor) {
  if (!anchor?.element.isConnected) return

  // Measure after insertion so Chrome's own scroll anchoring is already accounted for.
  const offset = anchor.element.getBoundingClientRect().top - anchor.top
  if (offset) window.scrollBy({ top: offset, left: 0, behavior: "instant" })
}

export function streamPageHtml(html) {
  const document = new DOMParser().parseFromString(html, "text/html")
  return document.querySelector("[data-stream-page-container]")?.innerHTML || html
}

function insertStreamPage(sentinel, html, direction) {
  const template = document.createElement("template")
  template.innerHTML = html
  const fragment = template.content

  if (direction === "prepend") {
    sentinel.after(fragment)
    mergeAdjacentDayGroup(sentinel.nextElementSibling, "prepend")
  } else {
    sentinel.before(fragment)
    mergeAdjacentDayGroup(sentinel.previousElementSibling, "append")
  }
}

function mergeAdjacentDayGroup(insertedEdge, direction) {
  const insertedGroup = edgeDayGroup(insertedEdge, direction)
  if (!insertedGroup) return

  const neighborGroup = direction === "prepend"
    ? nextDayGroupAfter(insertedGroup)
    : previousDayGroupBefore(insertedGroup)

  if (!neighborGroup || neighborGroup.dataset.photoDayGroupKey !== insertedGroup.dataset.photoDayGroupKey) return

  if (direction === "prepend") {
    prependCards(neighborGroup, insertedGroup)
  } else {
    appendCards(neighborGroup, insertedGroup)
  }

  insertedGroup.remove()
}

function edgeDayGroup(element, direction) {
  const groups = dayGroupsFrom(element)
  return direction === "prepend" ? groups.at(-1) : groups[0]
}

function dayGroupsFrom(element) {
  if (!element) return []
  if (element.matches?.("[data-photo-day-group-key]")) return [element]
  return Array.from(element.querySelectorAll?.("[data-photo-day-group-key]") || [])
}

function previousDayGroupBefore(group) {
  let element = group.previousElementSibling
  while (element) {
    const groups = dayGroupsFrom(element)
    if (groups.length > 0) return groups.at(-1)
    element = element.previousElementSibling
  }
}

function nextDayGroupAfter(group) {
  let element = group.nextElementSibling
  while (element) {
    const groups = dayGroupsFrom(element)
    if (groups.length > 0) return groups[0]
    element = element.nextElementSibling
  }
}

function appendCards(targetGroup, sourceGroup) {
  const targetGrid = targetGroup.querySelector(".photo-day-group-grid")
  const sourceGrid = sourceGroup.querySelector(".photo-day-group-grid")
  if (!targetGrid || !sourceGrid) return

  demoteDayStart(sourceGrid.firstElementChild)
  targetGrid.append(...sourceGrid.children)
}

function prependCards(targetGroup, sourceGroup) {
  const targetGrid = targetGroup.querySelector(".photo-day-group-grid")
  const sourceGrid = sourceGroup.querySelector(".photo-day-group-grid")
  if (!targetGrid || !sourceGrid) return

  demoteDayStart(targetGrid.firstElementChild)
  targetGrid.prepend(...sourceGrid.children)
}

function demoteDayStart(card) {
  if (!card) return

  card.querySelector(".photo-day-marker")?.remove()
  card.removeAttribute("data-stream-date-group-key")
}
