export async function appendNextStreamPage(sentinel, loadingLabel = "Loading...") {
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

    const html = await response.text()
    sentinel.insertAdjacentHTML("beforebegin", html)
    sentinel.remove()
    return true
  } finally {
    clearTimeout(timeout)
  }
}
