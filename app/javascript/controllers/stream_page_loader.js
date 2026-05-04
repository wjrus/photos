export async function appendNextStreamPage(sentinel, loadingLabel = "Loading...") {
  return loadStreamPage(sentinel, loadingLabel, "beforebegin")
}

export async function prependPreviousStreamPage(sentinel, loadingLabel = "Loading...") {
  const previousHeight = document.documentElement.scrollHeight
  const loaded = await loadStreamPage(sentinel, loadingLabel, "afterend")
  const heightDelta = document.documentElement.scrollHeight - previousHeight
  if (heightDelta > 0) window.scrollBy(0, heightDelta)
  return loaded
}

async function loadStreamPage(sentinel, loadingLabel, position) {
  const url = sentinel?.dataset.nextUrl
  if (!url) return false

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
    if (!html) {
      sentinel.textContent = "No more photos."
      return false
    }

    sentinel.insertAdjacentHTML(position, html)
    sentinel.remove()
    return true
  } finally {
    clearTimeout(timeout)
  }
}

export function streamPageHtml(html) {
  const document = new DOMParser().parseFromString(html, "text/html")
  return document.querySelector("[data-stream-page-container]")?.innerHTML || html
}
