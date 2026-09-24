require "application_system_test_case"

class StreamScrollTest < ApplicationSystemTestCase
  setup do
    @locked_folder_password = ENV["PHOTOS_LOCKED_FOLDER_PASSWORD"]
    @owner = users(:one)
    @owner.update!(password: "password12")
    blob = ActiveStorage::Blob.create_and_upload!(
      io: File.open(Rails.root.join("public/icon.png")),
      filename: "scroll-photo.png",
      content_type: "image/png"
    )
    @photos = 181.times.map do |index|
      Photo.create!(title: "Scroll photo #{index}", owner: @owner, captured_at: Time.zone.local(2024, 1, 1) + index.hours, original: blob)
    end
    @photos.first.original.variant(:stream).processed
    @album = @owner.photo_albums.create!(title: "Scroll album", source: "manual")
    @album.photos << @photos
    @photos.each do |photo|
      photo.create_metadata!(extraction_status: "complete", latitude: 40, longitude: -80, raw: {})
    end
    @focus = @photos[90]

    visit sign_in_path
    fill_in "Email", with: @owner.email
    fill_in "Password", with: "password12"
    click_button "Sign in"
    assert_current_path root_path
  end

  teardown do
    ENV["PHOTOS_LOCKED_FOLDER_PASSWORD"] = @locked_folder_password
  end

  %w[home album location restricted].each do |stream|
    test "#{stream} keeps visible photos steady when scrolling after returning from the viewer" do
      path = stream_path(stream)
      visit path
      page.execute_script("window.scrollTo(0, document.documentElement.scrollHeight)")
      find("[data-photo-id='#{@focus.id}'] a").click
      assert_current_path photo_path(@focus)
      hold_page_responses
      find(".photo-viewer-shell").hover
      click_link "Return to stream"
      assert_current_path "#{path}?photo_id=#{@focus.id}"

      wait_for_page("newer")
      scroll_to(400)
      anchor = visible_photo
      release_page("newer")
      assert_selector "[data-photo-id]", count: 120
      assert_photo_stays_in_place(anchor)

      scroll_to(400)
      wait_for_page("newer")
      anchor = visible_photo
      release_page("newer")
      assert_selector "[data-photo-id]", count: 150
      assert_photo_stays_in_place(anchor)

      page.execute_script("window.scrollTo(0, document.documentElement.scrollHeight)")
      wait_for_page("older")
      anchor = visible_photo
      release_page("older")
      assert_selector "[data-photo-id]", count: 181
      assert_photo_stays_in_place(anchor)
      assert_equal 181, page.evaluate_script("new Set(Array.from(document.querySelectorAll('[data-photo-id]'), card => card.dataset.photoId)).size")
    end
  end

  test "Chrome Back restores the feed and resumes a page that was loading when the photo opened" do
    visit root_path
    assert_selector "[data-photo-id]", count: 120
    hold_page_responses
    page.execute_script("window.scrollTo(0, document.documentElement.scrollHeight)")
    wait_for_page("older")
    anchor = visible_photo
    find("[data-photo-id='#{anchor.fetch('id')}'] a").click
    assert_current_path photo_path(anchor.fetch("id"))
    page.go_back
    assert_current_path root_path

    page.document.synchronize(5) do
      raise Capybara::ExpectationNotMet, "The restored feed did not resume pagination" unless page.evaluate_script("pendingStreamPages.length >= 2")
    end
    assert_equal 2, page.evaluate_script("pendingStreamPages.length")
    assert_photo_stays_in_place(anchor)

    release_page("older")
    settle_layout
    assert_selector "[data-photo-id]", count: 120
    release_page("older")
    assert_selector "[data-photo-id]", count: 180
    assert_photo_stays_in_place(anchor)
  end

  test "overlapping earlier and later loads preserve the current photo on a narrow screen without browser anchoring" do
    browser = page.driver.browser
    browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: 390, height: 844, deviceScaleFactor: 1, mobile: true)
    browser.execute_cdp("Emulation.setTouchEmulationEnabled", enabled: true)
    visit photo_path(@focus, return_to: album_path(@album))
    assert_selector ".photo-viewer-shell"
    hold_page_responses
    click_link "Return to stream"
    assert_current_path album_path(@album, photo_id: @focus.id)
    page.execute_script("document.documentElement.style.overflowAnchor = 'none'")
    wait_for_page("newer")

    page.execute_script("window.scrollTo(0, document.documentElement.scrollHeight)")
    wait_for_page("older")
    anchor = visible_photo
    release_page("older")
    assert_selector "[data-photo-id]", count: 91
    assert_photo_stays_in_place(anchor)
    release_page("newer")
    assert_selector "[data-photo-id]", count: 151
    assert_photo_stays_in_place(anchor)
  ensure
    browser&.execute_cdp("Emulation.setTouchEmulationEnabled", enabled: false)
    browser&.execute_cdp("Emulation.clearDeviceMetricsOverride")
  end

  %w[home album location].each do |stream|
    test "#{stream} timeline follows the photos currently onscreen" do
      visit stream_path(stream)
      assert_selector "[data-photo-id]", count: 120
      page.execute_script("document.querySelectorAll('[data-photo-id]')[45].scrollIntoView({ block: 'start' })")
      settle_layout
      period = page.evaluate_script <<~JS
        Array.from(document.querySelectorAll('[data-photo-id]')).find(card => card.getBoundingClientRect().bottom > 120).dataset.streamTimelineDayKey
      JS
      assert_selector "[data-stream-timeline-target='item'][aria-current='date'][data-stream-timeline-period-key-value='#{period}']"
    end
  end

  test "preloading starts a page early and leaves distant thumbnails lazy" do
    visit photo_path(@focus)
    assert_selector ".photo-viewer-shell"
    hold_page_responses
    page.execute_script("Turbo.visit('/')")
    assert_current_path root_path
    wait_for_page("older")
    assert_selector "[data-photo-id]", count: 60
    distance = page.evaluate_script("document.querySelector('[data-infinite-scroll-target=sentinel]').getBoundingClientRect().top - innerHeight")
    assert_operator distance, :>, 800, "Pagination should start before the old 800px threshold"

    release_page("older")
    assert_selector "[data-photo-id]", count: 120
    settle_layout
    assert_equal 0, page.evaluate_script("pendingStreamPages.length")
    assert_equal 0, page.evaluate_script("scrollY")
    assert page.evaluate_script("document.querySelector('[data-photo-id] img').loading === 'lazy'")
    assert_not page.evaluate_script("Array.from(document.querySelectorAll('[data-photo-id] img')).at(-1).complete"), "Distant thumbnails should not compete with visible photos"

    page.execute_script("window.scrollTo(0, document.documentElement.scrollHeight)")
    wait_for_page("older")
    anchor = visible_photo
    release_page("older")
    assert_selector "[data-photo-id]", count: 180
    assert_photo_stays_in_place(anchor)
  end

  test "scroll restoration shares an already pending page request" do
    visit photo_path(@focus)
    assert_selector ".photo-viewer-shell"
    hold_page_responses
    page.execute_script("Turbo.visit('/')")
    assert_current_path root_path
    wait_for_page("older")
    page.evaluate_async_script <<~JS
      const done = arguments[0]
      import('controllers/stream_page_loader').then(loader => {
        const sentinel = document.querySelector('[data-infinite-scroll-target=sentinel]')
        window.restoredPage = loader.appendNextStreamPage(sentinel, 'Restoring...')
        done()
      })
    JS
    release_page("older")
    assert page.evaluate_async_script("const done = arguments[0]; restoredPage.then(done)")
    assert_selector "[data-photo-id]", count: 120
    assert_equal 0, page.evaluate_script("pendingStreamPages.length")
    assert_equal 120, page.evaluate_script("new Set(Array.from(document.querySelectorAll('[data-photo-id]'), card => card.dataset.photoId)).size")
  end

  test "failed page loads wait for scrolling before retrying" do
    visit photo_path(@focus)
    assert_selector ".photo-viewer-shell"
    page.execute_script <<~JS
      const originalFetch = window.fetch
      window.failedPageRequests = 0
      window.fetch = (...args) => {
        const url = new URL(args[0].url || args[0], location.href)
        if (url.searchParams.has('stream_page')) {
          window.failedPageRequests += 1
          return Promise.resolve(new Response('', { status: 503 }))
        }
        return originalFetch(...args)
      }
      Turbo.visit('/')
    JS
    assert_current_path root_path
    assert_text /Could not load more photos\. Scroll to retry\./i
    settle_layout
    assert_equal 1, page.evaluate_script("failedPageRequests")
    scroll_to(200)
    page.document.synchronize(5) do
      raise Capybara::ExpectationNotMet, "Scroll did not retry pagination" unless page.evaluate_script("failedPageRequests >= 2")
    end
    settle_layout
    assert_equal 2, page.evaluate_script("failedPageRequests")
    assert_selector "[data-photo-id]", count: 60
  end

  private

  def stream_path(stream)
    case stream
    when "home" then root_path
    when "album" then album_path(@album)
    when "location" then location_path(PhotoLocation.id_for_coordinates(40, -80))
    when "restricted"
      ENV["PHOTOS_LOCKED_FOLDER_PASSWORD"] = "synthetic-test-password"
      Photo.where(id: @photos.map(&:id)).update_all(restricted: true)
      visit restricted_photos_path
      fill_in "Password", with: "synthetic-test-password"
      click_button "Open"
      assert_button "Lock", wait: 5
      restricted_photos_path
    end
  end

  def hold_page_responses
    page.execute_script <<~JS
      const originalFetch = window.fetch
      window.pendingStreamPages = []
      window.fetch = async (...args) => {
        const response = await originalFetch(...args)
        const url = new URL(args[0].url || args[0], location.href)
        if (url.searchParams.has('stream_page')) {
          const direction = url.searchParams.has('newer_cursor') ? 'newer' : 'older'
          await new Promise(release => window.pendingStreamPages.push({ direction, release }))
        }
        return response
      }
    JS
  end

  def wait_for_page(direction)
    page.document.synchronize(5) do
      raise Capybara::ExpectationNotMet, "No #{direction} page requested" unless page.evaluate_script("pendingStreamPages.some(page => page.direction === arguments[0])", direction)
    end
  end

  def release_page(direction)
    page.execute_script <<~JS, direction
      const index = pendingStreamPages.findIndex(page => page.direction === arguments[0])
      pendingStreamPages.splice(index, 1)[0].release()
    JS
  end

  def scroll_to(y)
    page.execute_script("window.scrollTo(0, arguments[0])", y)
    settle_layout
  end

  def settle_layout
    page.evaluate_async_script("const done = arguments[0]; requestAnimationFrame(() => requestAnimationFrame(done))")
  end

  def visible_photo
    page.evaluate_script <<~JS
      (() => {
        const card = Array.from(document.querySelectorAll('[data-photo-id]')).find(card => {
          const rect = card.getBoundingClientRect()
          return rect.top >= 120 && rect.top < innerHeight
        })
        return { id: card.dataset.photoId, top: card.getBoundingClientRect().top }
      })()
    JS
  end

  def assert_photo_stays_in_place(anchor)
    settle_layout
    top = page.evaluate_script("document.querySelector('[data-photo-id=\"' + arguments[0] + '\"]').getBoundingClientRect().top", anchor.fetch("id"))
    assert_in_delta anchor.fetch("top"), top, 1, "Pagination moved the visible photo"
  end
end
