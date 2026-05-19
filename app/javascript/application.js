// Configure your import map in config/importmap.rb. Read more: https://github.com/rails/importmap-rails
import "@hotwired/turbo-rails"
import "controllers"

const THEME_STORAGE_KEY = "photos-theme"
const THEME_CHOICES = new Set(["system", "light", "dark", "paper", "terminal", "amber"])

const systemTheme = () => {
  return window.matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light"
}

const savedThemeChoice = () => {
  const storedTheme = window.localStorage.getItem(THEME_STORAGE_KEY)
  if (THEME_CHOICES.has(storedTheme)) return storedTheme

  return "system"
}

const applyThemeChoice = (choice) => {
  const safeChoice = THEME_CHOICES.has(choice) ? choice : "system"
  const resolvedTheme = safeChoice === "system" ? systemTheme() : safeChoice

  document.documentElement.dataset.theme = resolvedTheme
  document.documentElement.dataset.themeChoice = safeChoice

  document.querySelectorAll("[data-theme-select]").forEach((select) => {
    select.value = safeChoice
  })
}

let themePickerInstalled = false

const installThemePicker = () => {
  applyThemeChoice(savedThemeChoice())

  if (themePickerInstalled) return

  document.addEventListener("change", (event) => {
    const select = event.target.closest("[data-theme-select]")
    if (!select) return

    const choice = THEME_CHOICES.has(select.value) ? select.value : "system"
    window.localStorage.setItem(THEME_STORAGE_KEY, choice)
    applyThemeChoice(choice)
  })

  window.matchMedia("(prefers-color-scheme: dark)").addEventListener("change", () => {
    if (savedThemeChoice() === "system") applyThemeChoice("system")
  })

  themePickerInstalled = true
}

document.addEventListener("turbo:load", installThemePicker)
document.addEventListener("DOMContentLoaded", installThemePicker)
