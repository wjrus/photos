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
    location("Cleveland", country: "United States", state: "Ohio", city: "Cleveland")
    location("Cleveland", country: "United States", state: "Michigan", city: "Cleveland")
    location("Gullfoss", country: "Iceland", state: "Southern Region")
    visit locations_path

    assert_selector "nav[aria-label='Sort locations'] a[aria-current='true']", text: "Geography"
    assert_selector "[data-location-country-group='Iceland']", count: 1
    assert_no_selector "[data-location-state-group='Southern Region']"
    assert_selector "[data-location-state-group='Ohio'] [data-location-title]", text: "Cleveland"
    assert_selector "[data-location-state-group='Michigan'] [data-location-title]", text: "Cleveland"
    assert_selector "[data-location-state-group='Ohio'] [data-location-context]", text: "United States · Ohio"
    [ 320, 390, 768, 1440 ].each do |width|
      page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: width, height: 900, deviceScaleFactor: 1, mobile: width < 640)
      assert_operator page.evaluate_script("document.documentElement.scrollWidth"), :<=, width + 1
      page.execute_script("arguments[0].scrollIntoView({block: 'start'})", find("[data-location-country-group='United States']"))
      page.save_screenshot(Rails.root.join("tmp/screenshots/locations-geography-#{width}.png")) if [ 390, 1440 ].include?(width)
    end
    within("nav[aria-label='Sort locations']") { click_link "Name" }
    assert_current_path locations_path(sort: "name")
    assert_no_selector "[data-location-country-group]"
    assert_selector "[data-location-context]", text: "United States · Ohio"
    assert_equal "Gullfoss", first("[data-location-title]").text
    assert_equal [ "Iceland", "United States · Michigan", "United States · Ohio" ], all("[data-location-context]").map(&:text)
    [ 320, 390, 1440 ].each do |width|
      page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: width, height: 900, deviceScaleFactor: 1, mobile: width < 640)
      assert_operator page.evaluate_script("document.documentElement.scrollWidth"), :<=, width + 1
      page.save_screenshot(Rails.root.join("tmp/screenshots/locations-name-hierarchy-#{width}.png")) if width == 390
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
  end
end
