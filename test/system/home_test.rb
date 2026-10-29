require "application_system_test_case"

class HomeTest < ApplicationSystemTestCase
  test "visiting the photo stream" do
    visit root_path

    assert_text "wjr photos"
    assert_link "Sign in"
    assert_selector "select[data-theme-select]"
    assert_no_text "ARCHIVE RULE"
    assert_no_text "Drop iPhone imports here"
    assert_no_text "Preserved privately."

    find("summary[aria-label='Site navigation']").click
    assert_link "Stream"
    assert_link "Albums"
    assert_no_link "Map"
  end

  test "the site name returns home without reopening navigation from a cached page" do
    visit root_path
    find("summary[aria-label='Site navigation']").click
    within("nav[aria-label='Site navigation']") { click_link "Albums" }
    assert_current_path albums_path

    page.execute_script(<<~JS)
      const originalFetch = window.fetch.bind(window)
      window.fetch = (url, ...args) => {
        if (new URL(url.url || url, location.href).pathname === '/') {
          return new Promise(resolve => {
            window.releaseHomeResponse = () => resolve(originalFetch(url, ...args))
          })
        }
        return originalFetch(url, ...args)
      }
    JS
    find("a.site-brand").click
    assert_current_path root_path
    assert_selector "html[data-turbo-preview]", visible: :all
    assert_no_selector "nav[aria-label='Site navigation']"
    assert_selector "summary[aria-label='Site navigation'][aria-expanded='false']"

    page.execute_script("window.releaseHomeResponse()")
    assert_no_selector "html[data-turbo-preview]", visible: :all
    assert_no_selector "nav[aria-label='Site navigation']"
    find("summary[aria-label='Site navigation']").click
    assert_selector "nav[aria-label='Site navigation']"
  end
end
