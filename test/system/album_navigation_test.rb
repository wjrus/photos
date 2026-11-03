require "application_system_test_case"

class AlbumNavigationTest < ApplicationSystemTestCase
  test "album back tab restores a sorted directory on a phone" do
    owner = users(:one)
    owner.update!(password: "synthetic-password12")
    24.times { |index| owner.photo_albums.create!(title: format("Trip %02d", index), source: "manual") }
    album = owner.photo_albums.create!(title: "Weekend trip", source: "manual")
    blob = File.open(Rails.root.join("public/icon.png")) do |image|
      ActiveStorage::Blob.create_and_upload!(io: image, filename: "album.png", content_type: "image/png")
    end
    album.photos << 12.times.map { |index| owner.photos.create!(title: "Photo #{index}", original: blob) }
    album.photos.first.original.variant(:stream).processed

    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: 390, height: 844, deviceScaleFactor: 1, mobile: true)
    visit sign_in_path
    fill_in "Email", with: owner.email
    fill_in "Password", with: "synthetic-password12"
    click_button "Sign in"
    assert_current_path root_path

    list_path = albums_path(sort: "letters")
    visit list_path
    selector = "[data-album-id='#{album.id}']"
    assert_no_selector selector
    until page.has_selector?(selector, wait: 0)
      # Infinite scroll can replace the sentinel between WebDriver commands.
      next_url = page.evaluate_script(<<~JS)
        (() => {
          const sentinel = document.querySelector("[data-infinite-scroll-target='sentinel']")
          sentinel?.scrollIntoView()
          return sentinel?.dataset.nextUrl
        })()
      JS
      if next_url
        assert_no_selector "[data-next-url='#{next_url}']"
      else
        assert_selector selector
      end
    end
    card = find(selector)
    page.execute_script("window.scrollTo(0, scrollY + arguments[0].getBoundingClientRect().top - 180)", card)
    offset = page.evaluate_script("arguments[0].getBoundingClientRect().top", card)
    card.find("a[data-directory-link]").click
    assert_current_path album_path(album, sort: "letters")
    assert_no_selector "[data-scroll-return-target='tab']"

    page.execute_script("Turbo.cache.clear(); window.scrollTo(0, 400)")
    within("header [data-scroll-return-target='tab']") { click_link "Back to albums" }
    assert_current_path list_path
    page.document.synchronize(10) do
      current_offset = page.evaluate_script("document.querySelector(arguments[0])?.getBoundingClientRect().top", selector)
      raise Capybara::ExpectationNotMet, "Album card position was not restored" unless current_offset && (current_offset - offset).abs <= 2
    end

    find(selector).find("a[data-directory-link]").click
    assert_current_path album_path(album, sort: "letters")
    page.execute_script("Turbo.cache.clear(); Turbo.visit(arguments[0])", list_path)
    assert_current_path list_path
    assert_selector "[data-controller~='directory-state']"
    assert_equal 0, page.evaluate_script("scrollY")
    assert_no_selector selector, visible: :all
  ensure
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
  end
end
