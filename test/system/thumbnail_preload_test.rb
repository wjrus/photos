require "application_system_test_case"

class ThumbnailPreloadTest < ApplicationSystemTestCase
  setup do
    owner = users(:one)
    owner.update!(password: "password12")
    @photo = Photo.create!(title: "Preload test photo", owner: owner, original: {
      io: File.open(Rails.root.join("public/icon.png")), filename: "preload.png", content_type: "image/png"
    })
    @photo.original.variant(:stream).processed
    @photo.create_metadata!(extraction_status: "complete", latitude: 40, longitude: -80, raw: {})
    @album = owner.photo_albums.create!(title: "Preload test album", source: "manual")
    @album.photos << @photo
    visit sign_in_path
    fill_in "Email", with: owner.email
    fill_in "Password", with: "password12"
    click_button "Sign in"
    assert_current_path root_path
  end

  test "all shared grids warm offscreen thumbnails on desktop and narrow screens" do
    [ 1400, 390 ].each do |width|
      page.current_window.resize_to(width, 1000)
      [ root_path, albums_path, album_path(@album), locations_path, location_path(PhotoLocation.id_for_coordinates(40, -80)) ].each_with_index do |path, index|
        visit path
        assert_selector "img[data-thumbnail-preload-target='image']"
        page.execute_script <<~JS, stream_photo_path(@photo, probe: "#{width}-#{index}")
          window.scrollTo(0, 0)
          const main = document.querySelector('#main-content')
          for (const [id, distance] of [['near-thumbnail', 1900], ['far-thumbnail', 15000]]) {
            const image = document.createElement('img')
            image.id = id
            image.loading = 'lazy'
            image.dataset.thumbnailPreloadTarget = 'image'
            image.style.cssText = `position:absolute;top:${innerHeight + distance}px;width:100px;height:100px`
            image.src = arguments[0] + '&distance=' + distance
            main.append(image)
          }
        JS
        page.document.synchronize(5) do
          ready = page.evaluate_script("document.querySelector('#near-thumbnail').loading === 'eager' && document.querySelector('#near-thumbnail').naturalWidth > 0")
          raise Capybara::ExpectationNotMet, "#{path} did not warm its offscreen thumbnail at width #{width}" unless ready
        end
        assert page.evaluate_script("document.querySelector('#near-thumbnail').getBoundingClientRect().top > innerHeight")
        assert_equal "lazy", page.evaluate_script("document.querySelector('#far-thumbnail').loading")
      end
    end
  ensure
    page.current_window.resize_to(1400, 1400)
  end

  test "lookahead limits concurrency and releases slots after errors or removed cards" do
    install_pending_images
    wait_for_promotions(6)
    assert_equal 6, promoted_count
    page.execute_script("document.querySelector('#pending-0').dispatchEvent(new Event('error'))")
    wait_for_promotions(7)
    assert_equal 7, promoted_count
    page.execute_script("document.querySelector('#pending-1').remove()")
    wait_for_promotions(7) # One removed, and one newly promoted.
    assert_equal "eager", page.evaluate_script("document.querySelector('#pending-7').loading")
  end

  test "data saver leaves offscreen thumbnails lazy" do
    visit albums_path
    # Keep the stub through Turbo navigation, rather than replacing navigator.
    page.execute_script <<~JS
      Object.defineProperty(navigator, 'connection', { configurable: true, value: { saveData: true } })
      Turbo.visit('/')
    JS
    assert_current_path root_path
    install_pending_images
    page.evaluate_async_script("const done = arguments[0]; setTimeout(done, 150)")
    assert_equal 0, promoted_count
  end

  %w[online focus visibilitychange].each do |event|
    test "failed thumbnails recover on #{event} without changing their URLs or reloading healthy images" do
      browser = page.driver.browser
      browser.execute_cdp("Network.enable")
      path = stream_photo_path(@photo, recovery_probe: event)
      browser.execute_cdp("Network.setBlockedURLs", urls: [ "*#{path}*" ])
      page.document.synchronize(5) do
        ready = page.evaluate_script("document.querySelector('img[data-thumbnail-preload-target=\"image\"]').naturalWidth > 0")
        raise Capybara::ExpectationNotMet, "Healthy thumbnail did not load" unless ready
      end
      page.execute_script <<~JS
        const healthy = document.querySelector('img[data-thumbnail-preload-target="image"]')
        healthy.addEventListener('load', () => { window.healthyReloads = (window.healthyReloads || 0) + 1 })
      JS
      install_failed_thumbnail(path)
      wait_for_image("complete && image.naturalWidth === 0")
      browser.execute_cdp("Network.setBlockedURLs", urls: [])
      page.execute_script(event == "visibilitychange" ? "document.dispatchEvent(new Event('visibilitychange'))" : "window.dispatchEvent(new Event(arguments[0]))", event)

      wait_for_image("complete && image.naturalWidth > 0")
      assert_equal path, page.evaluate_script("document.querySelector('#failed-thumbnail').getAttribute('src')")
      assert_equal 0, page.evaluate_script("window.healthyReloads || 0")
    ensure
      browser&.execute_cdp("Network.setBlockedURLs", urls: [])
    end
  end

  test "recovery pauses while hidden and stops after three failed attempts" do
    browser = page.driver.browser
    browser.execute_cdp("Network.enable")
    path = stream_photo_path(@photo, recovery_probe: "bounded")
    browser.execute_cdp("Network.setBlockedURLs", urls: [ "*#{path}*" ])
    page.execute_script("Object.defineProperty(document, 'hidden', { configurable: true, value: true })")
    install_failed_thumbnail(path)
    wait_for_failures(1)
    page.execute_script <<~JS
      window.dispatchEvent(new Event('online'))
      document.dispatchEvent(new Event('visibilitychange'))
    JS
    settle_recovery
    assert_equal 1, page.evaluate_script("window.thumbnailFailures")
    page.execute_script("delete document.hidden")

    3.times do |attempt|
      page.execute_script("window.dispatchEvent(new Event('focus'))")
      wait_for_failures(attempt + 2)
    end
    page.execute_script("window.dispatchEvent(new Event('focus'))")
    settle_recovery
    assert_equal 4, page.evaluate_script("window.thumbnailFailures")
  ensure
    page.execute_script("delete document.hidden")
    browser&.execute_cdp("Network.setBlockedURLs", urls: [])
  end

  test "a failure arriving after resume recovers without another focus event" do
    browser = page.driver.browser
    browser.execute_cdp("Network.enable")
    path = stream_photo_path(@photo, recovery_probe: "automatic")
    browser.execute_cdp("Network.setBlockedURLs", urls: [ "*#{path}*" ])
    install_failed_thumbnail(path)
    wait_for_failures(1)
    browser.execute_cdp("Network.setBlockedURLs", urls: [])

    wait_for_image("complete && image.naturalWidth > 0")
  ensure
    browser&.execute_cdp("Network.setBlockedURLs", urls: [])
  end

  private

  def install_failed_thumbnail(path)
    page.execute_script <<~JS, path
      window.thumbnailFailures = 0
      const image = document.createElement('img')
      image.id = 'failed-thumbnail'
      image.dataset.thumbnailPreloadTarget = 'image'
      image.style.cssText = 'width:100px;height:100px'
      image.addEventListener('error', () => window.thumbnailFailures++)
      document.querySelector('#main-content').prepend(image)
      requestAnimationFrame(() => { image.src = arguments[0] })
    JS
  end

  def wait_for_failures(count)
    page.document.synchronize(5) do
      raise Capybara::ExpectationNotMet, "Expected #{count} failed attempts" unless page.evaluate_script("window.thumbnailFailures") >= count
    end
  end

  def settle_recovery
    page.evaluate_async_script("const done = arguments[0]; requestAnimationFrame(() => requestAnimationFrame(() => setTimeout(done, 100)))")
  end

  def wait_for_image(condition)
    page.document.synchronize(5) do
      ready = page.evaluate_script("(() => { const image = document.querySelector('#failed-thumbnail'); return image && image.#{condition} })()")
      raise Capybara::ExpectationNotMet, "Thumbnail did not reach #{condition}" unless ready
    end
  end

  def install_pending_images
    page.execute_script <<~JS
      for (let index = 0; index < 12; index++) {
        const image = document.createElement('img')
        image.id = 'pending-' + index
        image.loading = 'lazy'
        image.dataset.thumbnailPreloadTarget = 'image'
        image.style.cssText = `position:absolute;top:${innerHeight + 1700 + index}px;width:100px;height:100px`
        // Model stalled downloads without making requests to an external host.
        Object.defineProperty(image, 'complete', { get: () => false })
        document.querySelector('#main-content').append(image)
      }
    JS
  end

  def promoted_count
    page.evaluate_script("document.querySelectorAll('img[id^=pending-][loading=eager]').length")
  end

  def wait_for_promotions(count)
    page.document.synchronize(5) do
      raise Capybara::ExpectationNotMet, "Expected #{count} warmed thumbnails" unless promoted_count == count
    end
  end
end
