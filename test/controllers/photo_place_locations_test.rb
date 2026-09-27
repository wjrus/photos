require "test_helper"

class PhotoPlaceLocationsTest < ActionDispatch::IntegrationTest
  setup do
    @owner = users(:one)
    OmniAuth.config.test_mode = true
    sign_in_as(@owner)
  end

  teardown do
    OmniAuth.config.mock_auth[:google_oauth2] = nil
    OmniAuth.config.test_mode = false
  end

  test "nearby venues and distant namesakes have separate pages and exact search filters" do
    cafe = geotagged_photo("Cafe photo", 44.7622, -85.5980)
    theater = geotagged_photo("Theater photo", 44.7623, -85.5981)
    namesake = geotagged_photo("Distant cafe photo", 42.1, -83.1)
    places = [
      assign_photo_place(cafe, name: "Main Street Cafe"),
      assign_photo_place(theater, name: "Local Theater"),
      assign_photo_place(namesake, name: "Main Street Cafe")
    ]

    get locations_path
    assert_response :success
    assert_select "article", count: 3
    places.each { |place| assert_select "a[href='#{location_path(PhotoLocation.id_for_place(place))}']" }

    [ cafe, theater, namesake ].zip(places).each do |photo, place|
      id = PhotoLocation.id_for_place(place)
      get location_path(id)
      assert_response :success
      assert_select "[data-photo-id]", count: 1
      assert_select "[data-photo-id='#{photo.id}']"

      get search_path(place_id: id)
      assert_response :success
      assert_select "[data-photo-id]", count: 1
      assert_select "[data-photo-id='#{photo.id}']"
    end

    assert_select "select#place_id option", text: /Main Street Cafe/, count: 2
    get search_path(q: "Main Street Cafe")
    assert_select "[data-photo-id]", count: 2
  end

  test "legacy name links offer a choice instead of merging distinct places" do
    first = geotagged_photo("West park", 40, -80)
    second = geotagged_photo("East park", 41, -81)
    places = [ first, second ].map { |photo| assign_photo_place(photo, name: "Riverside Park") }

    get location_path(PhotoLocation.place_id_for_name("Riverside Park"))

    assert_response :success
    assert_select "h1", text: "Choose a location"
    assert_select "article", count: 2
    assert_select "[data-photo-id]", count: 0
    places.each { |place| assert_select "a[href='#{location_path(PhotoLocation.id_for_place(place))}']" }

    first.publish!
    sign_in_as(users(:two))
    get location_path(PhotoLocation.place_id_for_name("Riverside Park"))
    assert_redirected_to location_path(PhotoLocation.id_for_place(places.first))
  end

  test "old shared cell names cannot override assigned venues or unresolved photos" do
    first = geotagged_photo("Restaurant", 44.7622, -85.5980)
    second = geotagged_photo("Neighboring shop", 44.7623, -85.5981)
    unresolved = geotagged_photo("Not yet matched", 44.7624, -85.5982)
    place = assign_photo_place(first, name: "Restaurant")
    other = assign_photo_place(second, name: "Shop")
    cell_id = PhotoLocation.id_for_coordinates(first.metadata.latitude, first.metadata.longitude)
    legacy = PhotoLocationPlace.create!(location_id: cell_id, name: "Overbroad old name")

    get locations_path
    assert_response :success
    assert_select "article", count: 3
    refute_includes response.body, legacy.name

    get location_path(PhotoLocation.place_id_for_name(legacy.name))
    assert_response :success
    assert_select "h1", text: "Choose a location"
    assert_select "article", count: 3

    get location_path(PhotoLocation.id_for_area(cell_id))
    assert_response :success
    assert_select "[data-photo-id]", count: 1
    assert_select "[data-photo-id='#{unresolved.id}']"

    patch location_cover_path(PhotoLocation.id_for_place(place), second)
    assert_response :not_found
    patch location_cover_path(PhotoLocation.id_for_place(other), second)
    assert_redirected_to location_path(PhotoLocation.id_for_place(other))

    get location_path(cell_id)
    assert_response :success
    assert_select "[data-photo-id]", count: 3
    assert_select "[data-photo-id='#{unresolved.id}']"
    refute_includes css_select("h1").first.text, legacy.name
  end

  test "a saved cover cannot follow a photo into another place" do
    cover = geotagged_photo("Old cover", 40, -80)
    remaining = geotagged_photo("Remaining at A", 40.1, -80.1)
    [ cover, remaining ].each { |photo| photo.original.variant(:stream).processed }
    place_a = assign_photo_place(cover, name: "Place A")
    assign_photo_place(remaining, place: place_a)
    @owner.photo_location_covers.create!(location_id: PhotoLocation.id_for_place(place_a), cover_photo: cover)
    assign_photo_place(cover, name: "Place B")

    get locations_path

    assert_response :success
    assert_select "a[href='#{location_path(PhotoLocation.id_for_place(place_a))}']" do
      assert_select "img[alt='Old cover']", count: 0
      assert_select "img[alt='Remaining at A']"
    end
  end

  test "search disambiguation uses only the viewers accessible coordinates" do
    hidden = geotagged_photo("Private corner", 40, -80)
    visible = geotagged_photo("Public corner", 40.2, -80.2)
    place = assign_photo_place(hidden, name: "Large park")
    assign_photo_place(visible, place: place)
    visible.publish!
    sign_in_as(users(:two))

    get search_path

    assert_response :success
    assert_select "select#place_id option", text: /Large park.*40.2000, -80.2000/
    assert_select "select#place_id option", text: /40.0000, -80.0000/, count: 0
  end

  test "place bounds never combine different identities with the same name" do
    first = geotagged_photo("First park", 40, -80)
    second = geotagged_photo("Second park", 50, -70)
    places = [ first, second ].map { |photo| assign_photo_place(photo, name: "Park") }

    PhotoLocationBound.refresh_all!

    places.zip([ first, second ]).each do |place, photo|
      bounds = PhotoLocationBound.find_by!(location_id: PhotoLocation.id_for_place(place))
      assert_equal 1, bounds.photo_count
      assert_equal photo.metadata.latitude, bounds.south
      assert_equal photo.metadata.latitude, bounds.north
    end
    refute PhotoLocationBound.exists?(location_id: PhotoLocation.place_id_for_name("Park"))
  end

  test "location cards paginate all places without loading every place record" do
    now = Time.current
    place_ids = PhotoPlace.insert_all!(501.times.map do |index|
      { identity_key: "pagination:#{index}", name: "Place #{index}", created_at: now, updated_at: now }
    end).rows.flatten
    photo_ids = Photo.insert_all!(501.times.map do |index|
      { owner_id: @owner.id, title: "Photo #{index}", created_at: now, updated_at: now }
    end).rows.flatten
    PhotoMetadata.insert_all!(photo_ids.zip(place_ids).map do |photo_id, place_id|
      { photo_id: photo_id, photo_place_id: place_id, latitude: 40, longitude: -80, created_at: now, updated_at: now }
    end)

    instantiated = 0
    subscriber = ->(event) { instantiated += event.payload[:record_count] if event.payload[:class_name] == "PhotoPlace" }
    ActiveSupport::Notifications.subscribed(subscriber, "instantiation.active_record") do
      get locations_path
    end
    assert_response :success
    assert_includes response.body, "501 photo locations"
    assert_select "article", count: 12
    assert_equal 12, instantiated

    get locations_path(page: 42)
    assert_response :success
    assert_select "article", count: 9
    assert_select "[data-infinite-scroll-target='sentinel']", count: 0
  end

  private

  def geotagged_photo(title, latitude, longitude)
    photo = @owner.photos.create!(
      title: title,
      original: { io: File.open(Rails.root.join("public/icon.png")), filename: "place.png", content_type: "image/png" }
    )
    photo.create_metadata!(latitude: latitude, longitude: longitude, extraction_status: "complete", raw: {})
    photo
  end

  def sign_in_as(user)
    OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new(
      provider: user.provider, uid: user.uid,
      info: { email: user.email, name: user.name, image: user.avatar_url }
    )
    post "/auth/google_oauth2"
    follow_redirect!
  end
end
