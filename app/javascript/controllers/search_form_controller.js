import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["query"]

  clearQuery() {
    this.queryTarget.value = ""
    this.queryTarget.focus()
  }
}
