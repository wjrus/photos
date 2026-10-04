require "application_system_test_case"
require "axe/dsl"
require_relative "../support/photo_book_test_helper"

class PhotobooksTest < ApplicationSystemTestCase
  include PhotoBookTestHelper

  setup do
    @owner = users(:one)
    @owner.update!(password: "synthetic-password12")
    @book, @photo = book_with_photo
    @second = book_photo(title: "Synthetic sunset", color: [ 170, 90, 30 ])
    @book.add_photos!([ @second ])
    visit sign_in_path
    fill_in "Email", with: @owner.email
    fill_in "Password", with: "synthetic-password12"
    click_button "Sign in"
    assert_current_path root_path
    assert_selector "summary[aria-label='Account menu']"
  end

  teardown do
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
    page.driver.browser.manage.window.resize_to(1400, 1400)
  end

  test "designer supports live captions two photos and a facing-page spread" do
    visit photo_book_path(@book, page_id: @book.pages.first.id)
    assert_text "Beside the lake."
    select "Two photos side by side", from: "Page layout"
    select "Second photo", from: "Use the chosen photo as"
    find("button[aria-label='Use Synthetic sunset']").click
    fill_in "Second photo caption", with: "At sunset."
    assert_selector "#photobook-preview text", text: "At sunset."
    assert_equal "caption", @book.pages.first.reload.layout
    click_button "Save page"
    assert_text "Page saved."
    assert_equal "two_horizontal", @book.pages.first.reload.layout
    assert_equal @second.id, @book.pages.first.secondary_photo_id
    # A spread starts on inside page 2, on the left.
    second_page = @book.pages.to_a[1]
    visit photo_book_path(@book, page_id: second_page.id)
    select "Photo across two pages", from: "Page layout"
    select "Synthetic landscape", from: "First photo"
    assert_selector "#photobook-preview svg", count: 2
    assert_selector "#photobook-preview image", count: 2
    click_button "Save page"
    assert_text "Page saved."
    assert_equal "spread", second_page.reload.layout
    page.save_screenshot(Rails.root.join("tmp/screenshots/photobook-desktop.png"))
  end

  test "photobooks can be created and receive photos through library bulk controls" do
    visit new_photo_book_path
    fill_in "Book name", with: "New travel book"
    click_button "Create photobook"
    assert_text "New travel book"
    visit root_path
    card = find("article[data-photo-id='#{@photo.id}']")
    card.hover
    card.find("label.selection-control").click
    find("summary[aria-label='Add selected photos to a photobook']").click
    select "New travel book", from: "Existing photobook"
    click_button "Add to photobook"
    assert_text "Added 1 photo to New travel book"
    assert @owner.photo_books.find_by!(title: "New travel book").photos.exists?(@photo.id)
  end

  test "designer settings and pool work at mobile width and pass accessibility checks" do
    page.driver.browser.manage.window.resize_to(390, 844)
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: 390, height: 844, deviceScaleFactor: 1, mobile: false)
    visit photo_book_path(@book, page_id: @book.pages.first.id)
    select "Two photos stacked", from: "Page layout"
    select "Synthetic sunset", from: "Second photo"
    fill_in "Second photo caption", with: "A second memory."
    assert_selector "#photobook-preview text", text: "A second memory."
    assert_operator page.evaluate_script("document.documentElement.scrollWidth"), :<=, 390
    assert_axe_clean
    page.save_screenshot(Rails.root.join("tmp/screenshots/photobook-mobile.png"))
    click_button "Save page"
    assert_text "Page saved."
    visit edit_photo_book_path(@book)
    fill_in "Spine label", with: "Synthetic journeys · 2026"
    click_button "Save book settings"
    assert_text "Book settings saved."
    assert_equal "Synthetic journeys · 2026", @book.reload.spine_text
    visit photo_book_path(@book, tab: "photos")
    assert_text "Synthetic sunset"
    assert_operator page.evaluate_script("document.documentElement.scrollWidth"), :<=, 390
    assert_axe_clean
  end

  private

  def assert_axe_clean
    Axe::DSL.expect(page).to(Axe::Matchers.be_axe_clean.according_to("wcag2a", "wcag2aa", "wcag21a", "wcag21aa"))
    assert true
  rescue RuntimeError => error
    flunk error.message
  end
end
