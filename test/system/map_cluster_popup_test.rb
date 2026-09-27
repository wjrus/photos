require "application_system_test_case"

class MapClusterPopupTest < ApplicationSystemTestCase
  setup do
    @owner = users(:one)
    @owner.update!(password: "password12")
    @first, @second = [ "First place photo", "Second place photo" ].map do |title|
      Photo.create!(title: title, owner: @owner) do |photo|
        photo.original.attach(io: File.open(Rails.root.join("public/icon.png")), filename: "map.png", content_type: "image/png")
      end.tap do |photo|
        photo.create_metadata!(latitude: 44.7622, longitude: -85.5980, raw: {})
      end
    end

    visit sign_in_path
    fill_in "Email", with: @owner.email
    fill_in "Password", with: "password12"
    click_button "Sign in"
    assert_current_path root_path
  end

  test "a mixed-place popup offers zoom without sending users to one constituent place" do
    assign_place([ @first ], "First place")
    assign_place([ @second ], "Second place")

    render_cluster_popup

    within "#map-popup-test" do
      assert_text "2 nearby locations"
      assert_text "2 photos"
      assert_no_link "View location"
      click_button "Zoom in"
    end
    assert_equal 14, page.evaluate_script("window.mapPopupZoom")
    assert_equal({ "lat" => 44.7622, "lng" => -85.598 }, page.evaluate_script("window.mapPopupPosition"))
    assert_no_selector "#map-popup-test"
  end

  test "a single-place popup opens the exact place represented by its photos" do
    place = assign_place([ @first, @second ], "One actual place")

    render_cluster_popup

    within "#map-popup-test" do
      assert_text place.name
      click_link "View location"
    end
    assert_current_path location_path(PhotoLocation.id_for_place(place))
    assert_selector "[data-photo-id='#{@first.id}']"
    assert_selector "[data-photo-id='#{@second.id}']"
  end

  test "a regional popup zooms past the region grouping breakpoint" do
    [ [ @first, 51.501, -0.141 ], [ @second, 51.462, -0.302 ] ].each do |photo, latitude, longitude|
      photo.metadata.update!(latitude: latitude, longitude: longitude)
      assign_place([ photo ], photo.title).update!(map_region_key: "test:gb:greater-london", map_region_name: "London")
    end

    render_cluster_popup(zoom: 4)

    within "#map-popup-test" do
      assert_text "London"
      assert_no_link "View location"
      click_button "Zoom in"
    end
    assert_equal 11, page.evaluate_script("window.mapPopupZoom")
    assert_equal false, page.evaluate_script("window.mapPopupController.ignoreNextIdle")
    assert_no_selector "#map-popup-test"
  end

  private

  def assign_place(photos, name)
    PhotoPlace.create!(identity_key: "test:#{SecureRandom.uuid}", name: name).tap do |place|
      photos.each { |photo| photo.metadata.update!(photo_place: place, location_source: "automatic") }
    end
  end

  def render_cluster_popup(zoom: 12)
    # Exercise the real popup and its endpoint without loading Google's map SDK.
    result = page.evaluate_async_script(<<~JS, map_markers_path(zoom: zoom), zoom)
      const url = arguments[0]
      const zoom = arguments[1]
      const done = arguments[arguments.length - 1]
      Promise.all([
        import("controllers/google_map_controller"),
        fetch(url, { headers: { Accept: "application/json" } }).then(response => response.json())
      ]).then(([module, payload]) => {
        const controller = Object.create(module.default.prototype)
        window.mapPopupController = controller
        const marker = payload.markers.find(item => item.type === "location")
        const popup = document.createElement("section")
        popup.id = "map-popup-test"
        popup.innerHTML = controller.locationInfoWindowContent(marker)
        document.body.prepend(popup)
        controller.activeLocationPosition = { lat: marker.latitude, lng: marker.longitude }
        controller.ignoreNextIdle = true
        controller.map = {
          panTo: position => window.mapPopupPosition = position,
          getZoom: () => zoom,
          setZoom: zoom => window.mapPopupZoom = zoom
        }
        controller.infoWindow = { close: () => popup.remove() }
        controller.bindInfoWindow()
        done("ready")
      }).catch(error => done(error.message))
    JS
    assert_equal "ready", result
  end
end
