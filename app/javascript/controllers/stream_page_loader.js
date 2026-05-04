export async function appendNextStreamPage(sentinel, loadingLabel = "Loading...") {
  const url = sentinel?.dataset.nextUrl
  if (!url) return false

  sentinel.textContent = loadingLabel
  const response = await fetch(url, { headers: { "Accept": "text/html" } })
  if (!response.ok) throw new Error("Could not load more photos.")

  const html = await response.text()
  sentinel.insertAdjacentHTML("beforebegin", html)
  sentinel.remove()
  return true
}
