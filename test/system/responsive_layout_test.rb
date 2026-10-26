require "application_system_test_case"

class ResponsiveLayoutTest < ApplicationSystemTestCase
  WIDTHS = [ 320, 390, 640, 768, 1440 ].freeze

  setup do
    @owner = users(:one)
    @owner.update!(password: "synthetic-password12", avatar_url: nil)
    @maps_key = ENV["GOOGLE_MAPS_EMBED_API_KEY"]
    ENV["GOOGLE_MAPS_EMBED_API_KEY"] = nil
    visit root_path
    find(".site-header select[data-theme-select]").select("Light")
  end

  teardown do
    ENV["GOOGLE_MAPS_EMBED_API_KEY"] = @maps_key
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
  end

  test "anonymous header controls align and sign in never wraps" do
    visit root_path
    WIDTHS.each do |width|
      viewport(width)
      screenshot("anonymous-#{width}")
      sign_in = find(".site-header a", text: "Sign in", exact_text: true)
      assert_single_line(sign_in)
      assert_aligned(find("summary[aria-label='Site navigation']"), sign_in)
      assert_no_horizontal_overflow
      if width < 640
        assert_no_selector ".site-header select[data-theme-select]"
      else
        picker = find(".site-header select[data-theme-select]")
        assert_aligned(picker, sign_in)
        assert_in_delta box(picker).fetch("height"), box(sign_in).fetch("height"), 1
      end
    end
    %w[light dark paper terminal amber].each do |theme|
      viewport(640)
      find(".site-header select[data-theme-select]").select(theme.capitalize)
      assert_no_horizontal_overflow
      assert_single_line(find(".site-header a", text: "Sign in", exact_text: true))
    end
  end

  test "account menus and selected photo actions fit narrow screens" do
    sign_in
    avatar_colors = page.evaluate_script("((element) => { const s = getComputedStyle(element); return [s.webkitTextFillColor, s.backgroundColor] })(document.querySelector('.site-header__account .text-white'))")
    assert_not_equal avatar_colors.first, avatar_colors.last, "Avatar initials should remain visible"
    photo = @owner.photos.create!(title: "Responsive lake", original: {
      io: File.open(Rails.root.join("public/icon.png")), filename: "responsive.png", content_type: "image/png"
    })
    album = @owner.photo_albums.create!(title: "Responsive album", source: "manual")
    album.photos << photo
    visit album_path(album)
    find("[data-photo-id='#{photo.id}']").hover
    find("[data-photo-id='#{photo.id}'] label[title='Select']").click
    assert_selector "#album-photo-bulk-form", visible: true

    WIDTHS.each do |width|
      viewport(width)
      assert_aligned(find("summary[aria-label='Site navigation']"), find("summary[aria-label='Account menu']"))
      assert_no_horizontal_overflow
      all("#album-photo-bulk-form > div button, #album-photo-bulk-form > div summary", visible: true).each do |button|
        assert_inside_viewport(button)
      end
      find("summary[aria-label='Add selected photos to an album']").click
      assert_inside_viewport(find("#album-photo-bulk-form details[open] > div"))
      screenshot("selected-actions-#{width}")
      find("summary[aria-label='Add selected photos to an album']").click
      find("summary[aria-label='Account menu']").click
      assert_inside_viewport(find(".site-menu-panel", text: "Sign out"))
      assert_inside_viewport(find(".site-menu-panel select[data-theme-select]"))
      screenshot("account-menu-#{width}")
      find("summary[aria-label='Account menu']").click
    end
  end

  test "filters and album creation panels stay inside the viewport" do
    sign_in
    WIDTHS.each do |width|
      viewport(width)
      visit search_path
      find("summary", text: "Filters", exact_text: true).click
      assert_inside_viewport(find("details[open] > div", text: "Clear filters"))
      assert_no_horizontal_overflow
      screenshot("search-filters-#{width}")
      visit albums_path
      find("summary", text: "New album", exact_text: true).click
      assert_inside_viewport(find("main details[open] > div"))
      assert_no_horizontal_overflow
      screenshot("new-album-#{width}")
    end
  end

  test "page toolbars and import tables fit phone and tablet widths" do
    sign_in
    GoogleTakeoutImport.create!(zip_path: "/synthetic/photos-with-a-long-archive-name.zip", entry_name: "example.jpg", status: "imported")
    WIDTHS.each do |width|
      viewport(width)
      [ locations_path, map_path, imports_path, uploads_path, users_path ].each do |path|
        visit path
        assert_no_horizontal_overflow
        screenshot("#{path.delete_prefix('/')}-#{width}") if [ 390, 1440 ].include?(width)
      end
    end
  end

  test "locations can switch between name and photo count at mobile and desktop widths" do
    sign_in
    blob = ActiveStorage::Blob.create_and_upload!(io: File.open(Rails.root.join("public/icon.png")), filename: "location.png", content_type: "image/png")
    photos = 3.times.map do |index|
      photo = @owner.photos.create!(title: "Location photo #{index}", original: blob)
      photo.create_metadata!(latitude: 40, longitude: -80, extraction_status: "complete", raw: {})
      photo
    end
    assign_photo_place(photos.first, name: "Alpha lake")
    place = assign_photo_place(photos.second, name: "Zulu station")
    assign_photo_place(photos.third, place: place)
    visit locations_path
    assert_equal "Zulu station", first("article h2").text
    within("nav[aria-label='Sort locations']") { click_link "Name" }
    assert_current_path locations_path(sort: "name")
    assert_equal "Alpha lake", first("article h2").text
    [ 390, 1440 ].each do |width|
      viewport(width)
      assert_no_horizontal_overflow
      screenshot("locations-sorted-#{width}")
    end
    within("nav[aria-label='Sort locations']") { click_link "Photo count" }
    assert_current_path locations_path(sort: "count")
    assert_equal "Zulu station", first("article h2").text
  end

  private

  def sign_in
    visit sign_in_path
    fill_in "Email", with: @owner.email
    fill_in "Password", with: "synthetic-password12"
    click_button "Sign in"
    assert_current_path root_path
    find("button[data-action='dismissible#dismiss']").click if has_selector?("button[data-action='dismissible#dismiss']", wait: 0)
  end

  def viewport(width)
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: width, height: 900, deviceScaleFactor: 1, mobile: width < 640)
  end

  def box(element)
    page.evaluate_script("((element) => { const r = element.getBoundingClientRect(); return { left: r.left, right: r.right, top: r.top, height: r.height, center: r.top + r.height / 2 } })(arguments[0])", element)
  end

  def assert_aligned(first, second)
    assert_in_delta box(first).fetch("center"), box(second).fetch("center"), 1
  end

  def assert_single_line(element)
    lines = page.evaluate_script("((element) => { const r = document.createRange(); r.selectNodeContents(element); return r.getClientRects().length })(arguments[0])", element)
    assert_equal 1, lines, "Sign in should stay on one line"
  end

  def assert_inside_viewport(element)
    bounds = box(element)
    assert_operator bounds.fetch("left"), :>=, -1, "Panel extends past the left edge"
    assert_operator bounds.fetch("right"), :<=, page.evaluate_script("innerWidth") + 1, "Panel extends past the right edge"
  end

  def assert_no_horizontal_overflow
    assert_operator page.evaluate_script("document.documentElement.scrollWidth"), :<=, page.evaluate_script("innerWidth") + 1, "Page overflows at #{page.current_path}"
  end

  def screenshot(name)
    page.save_screenshot(Rails.root.join("tmp/screenshots/layout-#{name}.png"))
  end
end
