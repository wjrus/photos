import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = {
    apiKey: String,
    markersUrl: String
  }

  connect() {
    this.mapMarkers = []
    this.loadGoogleMaps().then(() => this.renderMap())
  }

  disconnect() {
    window.google?.maps?.event?.clearInstanceListeners(this.map)
  }

  loadGoogleMaps() {
    if (window.google?.maps) return Promise.resolve()

    window.photosGoogleMapsLoaded ||= new Promise((resolve, reject) => {
      const callbackName = "photosGoogleMapsCallback"
      window[callbackName] = resolve

      const script = document.createElement("script")
      script.src = `https://maps.googleapis.com/maps/api/js?key=${encodeURIComponent(this.apiKeyValue)}&callback=${callbackName}`
      script.async = true
      script.defer = true
      script.onerror = reject
      document.head.appendChild(script)
    })

    return window.photosGoogleMapsLoaded
  }

  renderMap() {
    this.bounds = new window.google.maps.LatLngBounds()
    this.map = new window.google.maps.Map(this.element, {
      clickableIcons: false,
      fullscreenControl: false,
      mapTypeControl: false,
      streetViewControl: false,
      center: { lat: 39.5, lng: -98.35 },
      zoom: 4
    })
    this.infoWindow = new window.google.maps.InfoWindow()
    this.infoWindow.addListener("domready", () => this.bindLocationInfoWindow())
    this.statusElement = this.status()

    this.map.addListener("idle", () => this.loadVisibleMarkers())
  }

  async loadVisibleMarkers() {
    const bounds = this.map.getBounds()
    if (!bounds) return

    const requestKey = bounds.toUrlValue(4)
    if (requestKey === this.lastRequestKey) return
    this.lastRequestKey = requestKey
    this.setStatus("Loading visible locations...")

    try {
      const payload = await this.fetchMarkers(bounds)
      this.replaceMarkers(payload.markers)
      this.setStatus(this.statusText(payload))
    } catch {
      this.setStatus("Could not load map locations.")
    }
  }

  async fetchMarkers(bounds) {
    const url = new URL(this.markersUrlValue, window.location.origin)
    const northEast = bounds.getNorthEast()
    const southWest = bounds.getSouthWest()
    url.searchParams.set("north", northEast.lat())
    url.searchParams.set("east", northEast.lng())
    url.searchParams.set("south", southWest.lat())
    url.searchParams.set("west", southWest.lng())
    url.searchParams.set("zoom", this.map.getZoom())

    const response = await fetch(url, { headers: { "Accept": "application/json" } })
    if (!response.ok) throw new Error("Could not load map markers.")
    return response.json()
  }

  replaceMarkers(markers) {
    this.mapMarkers.forEach((marker) => marker.setMap(null))
    this.mapMarkers = markers.map((marker) => this.buildMarker(marker))
  }

  buildMarker(marker) {
    const position = { lat: marker.latitude, lng: marker.longitude }
    const mapMarker = new window.google.maps.Marker({
      map: this.map,
      position,
      title: marker.title,
      label: marker.type === "location" ? this.locationLabel(marker.count) : undefined
    })

    mapMarker.addListener("click", () => {
      if (marker.type === "location") {
        this.activeLocationPosition = position
        this.infoWindow.setContent(this.locationInfoWindowContent(marker))
        this.infoWindow.open({ anchor: mapMarker, map: this.map })
        return
      }

      this.infoWindow.setContent(this.infoWindowContent(marker))
      this.infoWindow.open({ anchor: mapMarker, map: this.map })
    })

    return mapMarker
  }

  status() {
    const element = document.createElement("div")
    element.setAttribute("role", "status")
    element.setAttribute("aria-live", "polite")
    element.style.cssText = "background:white;border-radius:8px;box-shadow:0 1px 8px rgba(0,0,0,.18);font:600 12px system-ui,sans-serif;margin:12px;padding:8px 10px;"
    this.map.controls[window.google.maps.ControlPosition.TOP_LEFT].push(element)
    return element
  }

  setStatus(message) {
    this.statusElement.textContent = message
  }

  statusText(payload) {
    if (payload.total === 0) return "No visible geotagged photos."

    const noun = payload.total === 1 ? "photo" : "photos"
    const visible = payload.locations.toLocaleString()
    const total = payload.total.toLocaleString()
    return payload.limited ? `Showing ${visible} locations for ${total} visible ${noun}. Zoom in for more.` : `Showing ${visible} locations for ${total} visible ${noun}.`
  }

  locationLabel(count) {
    return {
      text: count > 999 ? "999+" : count.toString(),
      color: "#fff",
      fontSize: "12px",
      fontWeight: "700"
    }
  }

  infoWindowContent(marker) {
    const image = marker.media_url
      ? `<img src="${this.escapeAttribute(marker.media_url)}" alt="" style="width:160px;height:110px;object-fit:cover;border-radius:8px;margin-bottom:8px;">`
      : ""

    return `
      <div style="max-width:180px;">
        ${image}
        <div style="font-weight:600;margin-bottom:8px;">${this.escapeHtml(marker.title)}</div>
        <a href="${this.escapeAttribute(marker.photo_url)}" style="font-weight:600;">Open photo</a>
      </div>
    `
  }

  locationInfoWindowContent(marker) {
    const previews = (marker.preview_urls || []).slice(0, 6).map((url) => (
      `<img src="${this.escapeAttribute(url)}" alt="" style="width:54px;height:54px;object-fit:cover;border-radius:6px;">`
    )).join("")
    const previewGrid = previews
      ? `<div style="display:grid;grid-template-columns:repeat(3,54px);gap:4px;margin:8px 0 10px;">${previews}</div>`
      : ""

    return `
      <div style="max-width:190px;">
        <div style="font-weight:700;margin-bottom:2px;">${this.escapeHtml(marker.title)}</div>
        <div style="color:#52525b;font-size:12px;font-weight:600;">${marker.count.toLocaleString()} photos</div>
        ${previewGrid}
        <div style="display:flex;gap:8px;align-items:center;">
          <a href="${this.escapeAttribute(marker.location_url)}" style="font-weight:700;">View location</a>
          <button type="button" data-map-action="zoom-location" style="border:0;background:transparent;color:#0f766e;cursor:pointer;font:700 13px system-ui,sans-serif;padding:0;">Zoom in</button>
        </div>
      </div>
    `
  }

  bindLocationInfoWindow() {
    const button = document.querySelector("[data-map-action='zoom-location']")
    if (!button || !this.activeLocationPosition) return

    button.addEventListener("click", () => {
      this.map.panTo(this.activeLocationPosition)
      this.map.setZoom(Math.min(this.map.getZoom() + 2, 21))
      this.infoWindow.close()
    }, { once: true })
  }

  escapeHtml(value) {
    const element = document.createElement("div")
    element.textContent = value || ""
    return element.innerHTML
  }

  escapeAttribute(value) {
    return this.escapeHtml(value).replaceAll('"', "&quot;")
  }
}
