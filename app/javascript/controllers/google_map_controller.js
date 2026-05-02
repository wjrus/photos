import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = {
    apiKey: String,
    markers: Array
  }

  connect() {
    this.loadGoogleMaps().then(() => this.renderMap())
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
    const bounds = new window.google.maps.LatLngBounds()
    const map = new window.google.maps.Map(this.element, {
      clickableIcons: false,
      fullscreenControl: false,
      mapTypeControl: false,
      streetViewControl: false,
      zoom: 4
    })
    const infoWindow = new window.google.maps.InfoWindow()

    this.markersValue.forEach((marker) => {
      const position = { lat: marker.latitude, lng: marker.longitude }
      bounds.extend(position)

      const mapMarker = new window.google.maps.Marker({
        map,
        position,
        title: marker.title
      })

      mapMarker.addListener("click", () => {
        infoWindow.setContent(this.infoWindowContent(marker))
        infoWindow.open({ anchor: mapMarker, map })
      })
    })

    if (this.markersValue.length === 1) {
      map.setCenter(bounds.getCenter())
      map.setZoom(13)
    } else {
      map.fitBounds(bounds, 48)
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

  escapeHtml(value) {
    const element = document.createElement("div")
    element.textContent = value || ""
    return element.innerHTML
  }

  escapeAttribute(value) {
    return this.escapeHtml(value).replaceAll('"', "&quot;")
  }
}
