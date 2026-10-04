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
    @second.update!(description: "At sunset.")
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

  test "real drag and drop supports two photos and a facing-page spread" do
    visit photo_book_path(@book, page_id: @book.pages.first.id)
    assert_no_selector "#photobook-tray button[data-photo-id='#{@photo.id}']"
    click_button "Add a second photo"
    assert_select_value "Page layout", "two_horizontal"
    find("button[aria-label='Select Synthetic sunset']").drag_to(find("#photobook-preview button[data-photo-slot='secondary']"))
    assert_selector "#photobook-preview text", text: "At sunset."
    assert_no_selector "#photobook-tray button[data-photo-id='#{@second.id}']"
    assert_equal "caption", @book.pages.first.reload.layout
    click_button "Save page"
    assert_text "Page saved."
    assert_equal "two_horizontal", @book.pages.first.reload.layout
    assert_equal @second.id, @book.pages.first.secondary_photo_id
    second_page = @book.pages.to_a[1]
    visit photo_book_path(@book, page_id: second_page.id)
    check "Show used photos"
    find("button[aria-label='Select Synthetic landscape']").drag_to(find("#photobook-preview button[data-photo-slot='primary']"))
    assert_select_value "Page layout", "caption"
    select "Photo across two pages", from: "Page layout"
    assert_selector "#photobook-preview svg", count: 2
    assert_selector "#photobook-preview image", count: 2
    click_button "Save page"
    assert_text "Page saved."
    assert_equal "spread", second_page.reload.layout
    assert_axe_clean
    page.save_screenshot(Rails.root.join("tmp/screenshots/photobook-desktop.png"))
  end

  test "replacing and removing a placement returns unused photos without removing book membership" do
    blank = @book.pages.to_a[1]
    visit photo_book_path(@book, page_id: blank.id)
    find("button[aria-label='Select Synthetic sunset']").click
    find("#photobook-preview button[data-photo-slot='primary']").click
    assert_selector "#photobook-preview text", text: "At sunset."
    assert_no_selector "#photobook-tray button[data-photo-id='#{@second.id}']"
    fill_in "Caption or page text", with: "My own caption."
    check "Show used photos"
    find("button[aria-label='Select Synthetic landscape']").click
    find("button[aria-label='Place or replace first photo']").click
    assert_selector "#photobook-preview text", text: "My own caption."
    uncheck "Show used photos"
    assert_selector "#photobook-tray button[data-photo-id='#{@second.id}']"
    click_button "Save page"
    assert_text "Page saved."
    assert_equal @photo.id, blank.reload.primary_photo_id
    click_button "Remove first photo"
    assert_no_selector "#photobook-preview image"
    # The landscape remains used on page 1; it should not return to the unused tray.
    assert_no_selector "#photobook-tray button[data-photo-id='#{@photo.id}']"
    find("button[aria-label='Select Synthetic sunset']").click
    find("button[aria-label='Place or replace first photo']").click
    assert_selector "#photobook-preview image"
    click_button "Remove first photo"
    assert_selector "#photobook-tray button[data-photo-id='#{@second.id}']"
    click_button "Save page"
    assert_text "Page saved."
    assert_nil blank.reload.primary_photo_id
    assert_equal "My own caption.", blank.caption
    assert_equal 2, @book.photos.count
  end

  test "cover tray edits preview then save front and back independently" do
    visit photo_book_path(@book)
    assert_selector "#photobook-preview text", text: "Synthetic journeys"
    find("button[aria-label='Select Synthetic sunset']").drag_to(find("#photobook-preview button[data-photo-slot='primary']"))
    fill_in "Cover title", with: "A new cover"
    assert_selector "#photobook-preview text", text: "A new cover"
    assert_nil @book.reload.cover_photo_id
    click_button "Save cover"
    assert_text "Book settings saved."
    assert_equal @second.id, @book.reload.cover_photo_id
    click_link "Back cover", exact: true
    assert_selector ".photobook-page-link.is-active", text: "Back cover"
    check "Show used photos"
    find("button[aria-label='Select Synthetic landscape']").click
    find("button[aria-label='Place or replace cover photo']").click
    fill_in "Back cover text", with: "The end."
    assert_selector "#photobook-preview text", text: "The end."
    click_button "Save cover"
    assert_text "Book settings saved."
    assert_selector ".photobook-page-link.is-active", text: "Back cover"
    assert_equal @photo.id, @book.reload.back_photo_id
    assert_equal "The end.", @book.back_text
  end

  test "a delayed tray render cannot make a newly placed photo available again" do
    visit photo_book_path(@book, page_id: @book.pages.to_a[1].id)
    stale_tray = page.evaluate_async_script("const done = arguments[arguments.length - 1]; fetch(arguments[0], { headers: { Accept: 'text/vnd.turbo-stream.html' } }).then(response => response.text()).then(done)", tray_photo_book_path(@book))
    find("button[aria-label='Select Synthetic sunset']").click
    find("#photobook-preview button[data-photo-slot='primary']").click
    within "#photobook-tray" do
      assert_text "0 unused photos"
    end
    page.driver.browser.execute_async_script("const done = arguments[arguments.length - 1]; window.Turbo.renderStreamMessage(arguments[0]); requestAnimationFrame(() => requestAnimationFrame(done))", stale_tray)
    within "#photobook-tray" do
      assert_no_selector "button[data-photo-id='#{@second.id}']"
    end
    assert_selector "#photobook-preview image"
  end

  test "new books start with four pages and pages can be added and removed" do
    visit new_photo_book_path
    fill_in "Book name", with: "New travel book"
    click_button "Create photobook"
    assert_text "4 inside pages + 2 covers"
    assert_selector ".photobook-page-link", count: 6
    book = @owner.photo_books.find_by!(title: "New travel book")
    click_button "Add blank page"
    assert_text "Page added."
    assert_equal 5, book.pages.count
    accept_confirm { click_button "Remove page" }
    assert_text "Page removed."
    assert_equal 4, book.pages.count
    visit root_path
    card = find("article[data-photo-id='#{@photo.id}']")
    card.hover
    card.find("label.selection-control").click
    find("summary[aria-label='Add selected photos to a photobook']").click
    select "New travel book", from: "Existing photobook"
    click_button "Add to photobook"
    assert_text "Added 1 photo to New travel book"
    assert book.photos.exists?(@photo.id)
  end

  test "tray search and pagination preserve drafts and navigation warns before discarding them" do
    25.times do |index|
      photo = @owner.photos.create!(title: "Tray scene #{index}") { |record| record.original.attach(@photo.original.blob) }
      @book.add_photos!([ photo ])
    end
    visit photo_book_path(@book, page_id: @book.pages.first.id)
    fill_in "Caption or page text", with: "Keep this draft."
    within "#photobook-tray" do
      fill_in "Find a tray photo", with: "Tray scene"
      click_button "Find", exact: true
      assert_selector "button[data-photo-id]", count: 24
      click_link "More photos"
      assert_selector "button[data-photo-id]", count: 1
      assert_field "Find a tray photo", with: "Tray scene"
    end
    assert_field "Caption or page text", with: "Keep this draft."
    assert_equal "Beside the lake.", @book.pages.first.reload.caption
    dismiss_confirm { click_link "Page 2", exact: true }
    assert_field "Caption or page text", with: "Keep this draft."
    click_button "Save page"
    assert_text "Page saved."
    click_link "Page 2", exact: true
    assert_select_value "Page layout", "blank"
  end

  test "mobile and keyboard placement work without overflow and pass accessibility checks" do
    page.driver.browser.manage.window.resize_to(390, 844)
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: 390, height: 844, deviceScaleFactor: 1, mobile: false)
    visit photo_book_path(@book, page_id: @book.pages.first.id)
    select "Two photos stacked", from: "Page layout"
    find("button[aria-label='Select Synthetic sunset']").send_keys(:space)
    find("button[aria-label='Place or replace second photo']").send_keys(:space)
    assert_selector "input[name='photo_book_page[secondary_photo_id]'][value='#{@second.id}']", visible: :all
    fill_in "Second photo caption", with: "A second memory."
    assert_selector "#photobook-preview text", text: "A second memory."
    assert_no_selector "#photobook-tray button[data-photo-id='#{@second.id}']"
    assert_operator page.evaluate_script("document.documentElement.scrollWidth"), :<=, 390
    assert_axe_clean
    page.execute_script("window.scrollTo({ top: 0, behavior: 'instant' })")
    assert_selector ".photobook-page-link.is-active", text: "Page 1"
    page.driver.browser.execute_async_script("const done = arguments[0]; requestAnimationFrame(() => requestAnimationFrame(done))")
    page.save_screenshot(Rails.root.join("tmp/screenshots/photobook-mobile.png"))
    page.execute_script("document.querySelector('#photobook-preview').scrollIntoView({ block: 'center' })")
    page.save_screenshot(Rails.root.join("tmp/screenshots/photobook-mobile-preview.png"))
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

  def assert_select_value(label, value)
    assert_field label, with: value
  end

  def assert_axe_clean
    Axe::DSL.expect(page).to(Axe::Matchers.be_axe_clean.according_to("wcag2a", "wcag2aa", "wcag21a", "wcag21aa"))
    assert true
  rescue RuntimeError => error
    flunk error.message
  end
end
