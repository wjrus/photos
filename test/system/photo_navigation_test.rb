require "application_system_test_case"

class PhotoNavigationTest < ApplicationSystemTestCase
  setup do
    @owner = users(:one)
    @owner.update!(password: "password12")
    @album = @owner.photo_albums.create!(title: "Navigation album", source: "manual")
    @previous, @current, @next = (1..3).map { |day| attached_photo(day) }
    @album.photos << [ @previous, @current, @next ]

    visit sign_in_path
    fill_in "Email", with: @owner.email
    fill_in "Password", with: "password12"
    click_button "Sign in"
    assert_current_path root_path
  end

  test "side arrows and arrow keys follow the album order and stop at its ends" do
    open_viewer
    assert_side_arrows

    click_link "Next item in stream"
    assert_photo @next
    assert_no_selector "a[aria-label='Next item in stream']"
    assert_no_navigation { find("body").send_keys(:arrow_right) }

    find("body").send_keys(:arrow_left)
    assert_photo @current
    find_link("Next item in stream").send_keys(:arrow_left)
    assert_photo @previous
    assert_no_selector "a[aria-label='Previous item in stream']"
    assert_no_navigation { find("body").send_keys(:arrow_left) }
    assert_operator find_link("Next item in stream").native.rect.x, :>, page.evaluate_script("innerWidth / 2")

    find("body").send_keys(:arrow_right)
    assert_photo @current
    click_link "Previous item in stream"
    assert_photo @previous
  end

  test "side arrows leave room for the information panel and caption editing" do
    open_viewer
    click_button "Show photo information"
    assert_selector ".photo-stream-navigation" do |navigation|
      navigation.native.rect.x + navigation.native.rect.width < page.evaluate_script("innerWidth - 390")
    end
    assert_side_arrows(panel_open: true)
    find("summary", text: "Add caption").click
    fill_in "Caption", with: "A caption to edit"

    assert_no_navigation do
      find_field("Caption").send_keys(:arrow_left, :arrow_right, :arrow_up, :arrow_down, :escape)
    end
    assert_field "Caption", with: "A caption to edit"

    find(".photo-viewer-shell").hover
    click_link "Next item in stream"
    assert_photo @next
    assert_selector "#photo-info-panel:not(.translate-x-full)"
  end

  test "zoom panning and ordinary scrolling do not change photos" do
    open_viewer
    assert_no_navigation do
      find("body").send_keys(:arrow_up, :arrow_down, [ :shift, :arrow_right ])
      page.execute_script <<~JS
        document.querySelector(".photo-viewer-shell").dispatchEvent(
          new WheelEvent("wheel", { deltaY: 120, bubbles: true, cancelable: true })
        )
      JS
    end

    click_button "Show zoom controls"
    click_button "Zoom in"
    frame = find("[data-photo-zoom-target='frame']")
    assert_no_navigation { frame.send_keys(:arrow_right) }
    assert_match(/translate3d\(-[\d.]+px, 0px, 0px\) scale\(1.25\)/, find(".photo-detail-media")[:style])

    click_link "Next item in stream"
    assert_photo @next
  end

  test "touch viewers show tappable side arrows without hover or slide animations" do
    browser = page.driver.browser
    browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: 390, height: 844, deviceScaleFactor: 1, mobile: true)
    browser.execute_cdp("Emulation.setTouchEmulationEnabled", enabled: true)
    open_viewer(hover: false)

    assert page.evaluate_script("matchMedia('(hover: none)').matches")
    assert_side_arrows
    assert_equal "1", page.evaluate_script("getComputedStyle(document.querySelector('.photo-stream-navigation')).opacity")
    assert_equal "none", page.evaluate_script("getComputedStyle(document.querySelector('.photo-zoom-frame')).transform")

    assert_no_navigation do
      page.execute_script <<~JS
        const viewer = document.querySelector(".photo-viewer-shell")
        for (const [type, y] of [["touchstart", 500], ["touchend", 100]]) {
          viewer.dispatchEvent(new TouchEvent(type, {
            bubbles: true,
            changedTouches: [new Touch({ identifier: 1, target: viewer, clientX: 195, clientY: y })]
          }))
        }
      JS
    end
    assert_no_selector "[class*='photo-viewer-shell--exit-']"

    click_link "Next item in stream"
    assert_photo @next
    click_link "Previous item in stream"
    assert_photo @current
  ensure
    browser&.execute_cdp("Emulation.setTouchEmulationEnabled", enabled: false)
    browser&.execute_cdp("Emulation.clearDeviceMetricsOverride")
  end

  test "browsing replaces viewer history and Escape returns to the current album" do
    visit album_path(@album)
    find("a[href='#{photo_path(@current)}']").click
    assert_photo @current

    find("body").send_keys(:arrow_right)
    assert_photo @next
    page.go_back
    assert_current_path album_path(@album)

    open_viewer
    find("body").send_keys(:arrow_right)
    assert_photo @next
    find("body").send_keys(:escape)
    assert_current_path album_path(@album, photo_id: @next.id)
  end

  private

  def attached_photo(day)
    Photo.create!(title: "Navigation photo #{day}", owner: @owner, captured_at: Time.zone.local(2024, 5, day)) do |photo|
      photo.original.attach(
        io: File.open(Rails.root.join("public/icon.png")),
        filename: "navigation-#{day}.png",
        content_type: "image/png"
      )
    end
  end

  def open_viewer(hover: true)
    visit photo_path(@current, return_to: album_path(@album))
    assert_photo @current
    find(".photo-viewer-shell").hover if hover
  end

  def assert_photo(photo)
    assert_current_path photo_path(photo)
    assert_selector ".photo-detail-media[alt='#{photo.title}']"
    assert_selector "[data-photo-zoom-target='frame'][tabindex='-1']"
  end

  def assert_side_arrows(panel_open: false)
    previous = find_link("Previous item in stream").native.rect
    following = find_link("Next item in stream").native.rect
    width, height = page.evaluate_script("[innerWidth, innerHeight]")
    right_edge = panel_open ? width - 390 : width

    assert_operator previous.x, :<, 25
    assert_operator following.x, :>, right_edge - 90
    assert_operator following.x + following.width, :<, right_edge
    [ previous, following ].each do |rect|
      assert_operator rect.width, :>=, 44
      assert_operator rect.height, :>=, 44
      assert_in_delta height / 2.0, rect.y + rect.height / 2.0, 1
    end
  end

  def assert_no_navigation
    page.execute_script <<~JS
      window.navigationAttempts = []
      window.recordNavigation = event => window.navigationAttempts.push(event.detail.url)
      document.addEventListener("turbo:before-visit", window.recordNavigation)
    JS
    yield
    assert_empty page.evaluate_script("window.navigationAttempts")
  ensure
    page.execute_script("document.removeEventListener('turbo:before-visit', window.recordNavigation)")
  end
end
