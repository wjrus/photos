import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  clear() {
    sessionStorage.removeItem("photos.streamState")
    document.cookie = "photos_return_to=; path=/; max-age=0; samesite=lax"
  }
}
