require "application_system_test_case"

class LocationGeographyTest < ApplicationSystemTestCase
  setup do
    @owner = users(:one)
    @owner.update!(password: "synthetic-password12")
    @blob = ActiveStorage::Blob.create_and_upload!(io: File.open(Rails.root.join("public/icon.png")), filename: "location.png", content_type: "image/png")
    visit sign_in_path
    fill_in "Email", with: @owner.email
    fill_in "Password", with: "synthetic-password12"
    click_button "Sign in"
    assert_current_path root_path
  end

  teardown do
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
  end

  test "geography shows country state and city context at phone and desktop widths" do
    location("Cleveland", country: "United States", state: "Ohio", city: "Cleveland").original.variant(:stream).processed
    location("Cleveland", country: "United States", state: "Michigan", city: "Cleveland")
    location("Gullfoss", country: "Iceland", state: "Southern Region")
    visit locations_path

    assert_no_selector "nav[aria-label='Sort locations']"
    assert_selector "[data-location-country-group='Iceland']", count: 1
    assert_no_selector "[data-location-state-group='Southern Region']"
    assert_selector "[data-location-state-group='Ohio'] [data-location-title]", text: "Cleveland"
    assert_selector "[data-location-state-group='Michigan'] [data-location-title]", text: "Cleveland"
    assert_selector "[data-location-state-group='Ohio'] [data-location-context]", text: "United States · Ohio"
    [ 320, 390, 768, 1440 ].each do |width|
      page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: width, height: 900, deviceScaleFactor: 1, mobile: width < 640)
      assert_operator page.evaluate_script("document.documentElement.scrollWidth"), :<=, width + 1
      page.execute_script("window.scrollTo(0, 0)")
      page.save_screenshot(Rails.root.join("tmp/screenshots/locations-geography-#{width}.png")) if [ 390, 1440 ].include?(width)
    end
    visit locations_path(sort: "name")
    assert_selector "[data-location-country-group='Iceland']"
    assert_selector "[data-location-context]", text: "United States · Ohio"
    assert_equal "Gullfoss", first("[data-location-title]").text
    assert_equal [ "Iceland", "United States · Michigan", "United States · Ohio" ], all("[data-location-context]").map(&:text)
    [ 320, 390, 1440 ].each do |width|
      page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: width, height: 900, deviceScaleFactor: 1, mobile: width < 640)
      assert_operator page.evaluate_script("document.documentElement.scrollWidth"), :<=, width + 1
      page.save_screenshot(Rails.root.join("tmp/screenshots/locations-single-view-#{width}.png")) if width == 390
    end
  end

  test "loading more locations merges country and state sections across page boundaries" do
    13.times { |index| location(format("Landmark %02d", index), country: "Iceland", state: "Southern Region") }
    location("Cleveland", country: "United States", state: "Michigan", city: "Cleveland")
    13.times { |index| location(format("Town %02d", index), country: "United States", state: "Ohio", city: format("Town %02d", index)) }
    visit locations_path
    assert_selector "article", minimum: 12

    result = page.evaluate_async_script(<<~JS)
      const done = arguments[arguments.length - 1]
      import("controllers/stream_page_loader").then(async module => {
        for (let i = 0; i < 4; i++) {
          const sentinel = document.querySelector("[data-infinite-scroll-target='sentinel']")
          if (!sentinel) break
          await module.appendNextStreamPage(sentinel)
        }
        done(document.querySelectorAll("article").length)
      }).catch(error => done(error.message))
    JS
    assert_equal 27, result
    assert_selector "[data-location-country-group='Iceland']", count: 1
    assert_selector "[data-location-country-group='United States']", count: 1
    assert_selector "[data-location-state-group='Michigan']", count: 1
    assert_selector "[data-location-state-group='Ohio']", count: 1
    assert_selector "[data-location-country-group='Iceland'] article", count: 13
    assert_selector "[data-location-state-group='Ohio'] article", count: 13
    assert_no_selector "[data-infinite-scroll-target='sentinel']"
    assert_equal (0...13).map { |index| format("Town %02d", index) }, all("[data-location-state-group='Ohio'] [data-location-title]").map(&:text)
  end

  %w[link browser].each do |return_method|
    test "#{return_method} back restores a location card after multiple directory pages" do
      if return_method == "browser"
        page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: 390, height: 844, deviceScaleFactor: 1, mobile: true)
      end
      photos = 40.times.map { |index| location(format("Landmark %02d", index), country: "Iceland", state: "Southern Region") }
      photos.first.original.variant(:stream).processed
      target_id = PhotoLocation.id_for_place(photos[26].metadata.photo_place)
      visit locations_path
      assert_no_selector "nav[aria-label='Sort locations']"
      assert page.evaluate_async_script(<<~JS, target_id)
        const id = arguments[0]
        const done = arguments[arguments.length - 1]
        import("controllers/stream_page_loader").then(async loader => {
          for (let i = 0; i < 5 && !document.querySelector(`[data-location-id="${CSS.escape(id)}"]`); i++) {
            const sentinel = document.querySelector("[data-infinite-scroll-target='sentinel']")
            if (!sentinel || !await loader.appendNextStreamPage(sentinel)) break
          }
          done(!!document.querySelector(`[data-location-id="${CSS.escape(id)}"]`))
        }).catch(() => done(false))
      JS
      card = find("[data-location-id='#{target_id}']")
      page.execute_script("window.scrollTo(0, scrollY + arguments[0].getBoundingClientRect().top - 180)", card)
      page.evaluate_async_script("const done=arguments[0]; requestAnimationFrame(() => requestAnimationFrame(done))")
      offset = page.evaluate_script("arguments[0].getBoundingClientRect().top", card)
      assert_operator page.evaluate_script("scrollY"), :>, 1500
      card.find("a[data-location-link]").click
      assert_current_path location_path(target_id)

      if return_method == "link"
        page.execute_script("Turbo.cache.clear()")
        click_link "Back to locations"
      else
        page.go_back
      end
      assert_current_path locations_path
      page.document.synchronize(10) do
        current_offset = page.evaluate_script("document.querySelector('[data-location-id=\"' + arguments[0] + '\"]')?.getBoundingClientRect().top", target_id)
        raise Capybara::ExpectationNotMet, "Location card position was not restored" unless current_offset && (current_offset - offset).abs <= 2
      end
      counts = page.evaluate_script(<<~JS)
        (() => {
          const cards = Array.from(document.querySelectorAll('[data-location-id]'))
          return { total: cards.length, unique: new Set(cards.map(card => card.dataset.locationId)).size }
        })()
      JS
      assert_equal counts.fetch("total"), counts.fetch("unique")
    end
  end

  private

  def location(name, country:, state:, city: nil)
    components = [
      { long_name: country, types: [ "country" ] }, { long_name: state, types: [ "administrative_area_level_1" ] },
      { long_name: "County", types: [ "administrative_area_level_2" ] }
    ]
    components << { long_name: city, types: [ "locality" ] } if city
    photo = @owner.photos.create!(title: name, original: @blob, captured_at: Time.zone.local(2022, 8, 17, 12))
    photo.create_metadata!(latitude: 41.5, longitude: -81.7, extraction_status: "complete", raw: {})
    assign_photo_place(photo, name: name, place_type: "premise", raw: { address_components: components })
    photo
  end
end
