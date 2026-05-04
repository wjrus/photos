require "test_helper"

class MapsControllerTest < ActionDispatch::IntegrationTest
  setup do
    OmniAuth.config.test_mode = true
    @owner = users(:one)
    @trusted_viewer_emails = ENV["PHOTOS_TRUSTED_VIEWER_EMAILS"]
    @google_maps_api_key = ENV["GOOGLE_MAPS_EMBED_API_KEY"]
    ENV["GOOGLE_MAPS_EMBED_API_KEY"] = "test-google-maps-key"
    sign_in_as(@owner)
  end

  teardown do
    ENV["PHOTOS_TRUSTED_VIEWER_EMAILS"] = @trusted_viewer_emails
    ENV["GOOGLE_MAPS_EMBED_API_KEY"] = @google_maps_api_key
    OmniAuth.config.mock_auth[:google_oauth2] = nil
    OmniAuth.config.test_mode = false
  end

  test "owner sees geotagged photos on map" do
    photo = attached_photo(title: "Northport")
    geotag(photo, latitude: 45.1317, longitude: -85.6165)
    album = @owner.photo_albums.create!(title: "North", source: "manual")

    get map_path

    assert_response :success
    assert_includes response.body, "Map"
    assert_includes response.body, "&lt; Stream"
    assert_includes response.body, "1 geotagged photo"
    assert_includes response.body, "All photos"
    assert_includes response.body, "North"
    assert_includes response.body, "test-google-maps-key"
    assert_select "[data-controller='google-map']"
    assert_select "[data-google-map-markers-url-value='#{map_markers_path}']"

    get map_markers_path(north: 46, south: 44, east: -84, west: -87)

    assert_response :success
    payload = JSON.parse(response.body)
    marker = payload.fetch("markers").find { |candidate| candidate.fetch("title") == "Northport" }
    assert marker
    assert_equal photo_path(photo, return_to: map_path), marker.fetch("photo_url")
  end

  test "owner can focus map on an album" do
    trip = @owner.photo_albums.create!(title: "Trip", source: "manual")
    other = @owner.photo_albums.create!(title: "Other", source: "manual")
    trip_photo = attached_photo(title: "Trip overlook")
    geotag(trip_photo, latitude: 44.7622, longitude: -85.5980)
    other_photo = attached_photo(title: "Other overlook")
    geotag(other_photo, latitude: 45.0, longitude: -86.0)
    trip.photos << trip_photo
    other.photos << other_photo

    get map_path(album_id: trip.id)

    assert_response :success
    refute_includes response.body, "Other overlook"
    assert_select "option[selected]", text: "Trip"
    assert_select "[data-google-map-markers-url-value='#{map_markers_path(album_id: trip.id)}']"

    get map_markers_path(album_id: trip.id, north: 46, south: 44, east: -84, west: -87)

    assert_response :success
    payload = JSON.parse(response.body)
    marker_titles = payload.fetch("markers").map { |marker| marker.fetch("title") }
    assert_includes marker_titles, "Trip overlook"
    refute_includes marker_titles, "Other overlook"
    marker = payload.fetch("markers").find { |candidate| candidate.fetch("title") == "Trip overlook" }
    assert_equal photo_path(trip_photo, return_to: map_path(album_id: trip.id)), marker.fetch("photo_url")
  end

  test "trusted viewer only sees public geotagged photos" do
    ENV["PHOTOS_TRUSTED_VIEWER_EMAILS"] = users(:two).email
    public_photo = attached_photo(title: "Public overlook")
    public_photo.publish!
    geotag(public_photo, latitude: 44.7622, longitude: -85.5980)
    private_photo = attached_photo(title: "Private driveway")
    geotag(private_photo, latitude: 45.0, longitude: -86.0)

    delete sign_out_path
    sign_in_as(users(:two))

    get map_path

    assert_response :success
    refute_includes response.body, "Private driveway"

    get map_markers_path(north: 46, south: 44, east: -84, west: -87)

    assert_response :success
    payload = JSON.parse(response.body)
    assert_equal 1, payload.fetch("total")
    assert_equal "Public overlook", payload.dig("markers", 0, "title")
  end

  test "anonymous viewer cannot see map" do
    delete sign_out_path

    get map_path

    assert_redirected_to root_path
  end

  test "map reports missing google maps key" do
    ENV["GOOGLE_MAPS_EMBED_API_KEY"] = nil
    photo = attached_photo(title: "Configured later")
    geotag(photo, latitude: 44.7622, longitude: -85.5980)

    get map_path

    assert_response :success
    assert_includes response.body, "Google Maps is not configured"
    assert_select "[data-controller='google-map']", false
  end

  private

  def geotag(photo, latitude:, longitude:)
    photo.create_metadata!(
      extraction_status: "complete",
      latitude: latitude,
      longitude: longitude,
      raw: {}
    )
  end

  def attached_photo(title:)
    photo = @owner.photos.new(title: title)
    photo.original.attach(
      io: File.open(Rails.root.join("public/icon.png")),
      filename: "#{title.parameterize}.png",
      content_type: "image/png"
    )
    photo.save!
    photo
  end

  def sign_in_as(user)
    OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new(
      provider: user.provider,
      uid: user.uid,
      info: {
        email: user.email,
        name: user.name,
        image: user.avatar_url
      }
    )

    post "/auth/google_oauth2"
    follow_redirect!
  end
end
