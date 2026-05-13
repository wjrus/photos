require "test_helper"

class MapsControllerTest < ActionDispatch::IntegrationTest
  setup do
    OmniAuth.config.test_mode = true
    @owner = users(:one)
    @trusted_viewer_emails = ENV["PHOTOS_TRUSTED_VIEWER_EMAILS"]
    @google_maps_api_key = ENV["GOOGLE_MAPS_EMBED_API_KEY"]
    @google_maps_map_id = ENV["GOOGLE_MAPS_MAP_ID"]
    ENV["GOOGLE_MAPS_EMBED_API_KEY"] = "test-google-maps-key"
    ENV["GOOGLE_MAPS_MAP_ID"] = "test-map-id"
    sign_in_as(@owner)
  end

  teardown do
    ENV["PHOTOS_TRUSTED_VIEWER_EMAILS"] = @trusted_viewer_emails
    ENV["GOOGLE_MAPS_EMBED_API_KEY"] = @google_maps_api_key
    ENV["GOOGLE_MAPS_MAP_ID"] = @google_maps_map_id
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
    assert_includes response.body, "Back to stream"
    assert_includes response.body, "1 geotagged photo"
    assert_includes response.body, "All photos"
    assert_includes response.body, "North"
    assert_includes response.body, "test-google-maps-key"
    assert_select "[data-controller='google-map']"
    assert_select "[data-google-map-map-id-value='test-map-id']"
    assert_select "[data-google-map-markers-url-value='#{map_markers_path}']"

    get map_markers_path(north: 46, south: 44, east: -84, west: -87)

    assert_response :success
    payload = JSON.parse(response.body)
    marker = payload.fetch("markers").find { |candidate| candidate.fetch("title") == "Northport" }
    assert marker
    assert_equal "photo", marker.fetch("type")
    assert_equal photo_path(photo), marker.fetch("photo_url")
    assert_equal map_path, marker.fetch("return_to")
  end

  test "markers groups nearby photos into locations at lower zoom levels" do
    first = attached_photo(title: "First overlook")
    second = attached_photo(title: "Second overlook")
    far = attached_photo(title: "Far overlook")
    geotag(first, latitude: 44.7622, longitude: -85.5980)
    geotag(second, latitude: 44.7630, longitude: -85.5970)
    geotag(far, latitude: 45.5, longitude: -86.5)
    PhotoLocationPlace.create!(
      location_id: location_id_for(first),
      name: "Traverse City, Michigan"
    )

    get map_markers_path(north: 46, south: 44, east: -84, west: -87, zoom: 10)

    assert_response :success
    payload = JSON.parse(response.body)
    location = payload.fetch("markers").find { |marker| marker.fetch("type") == "location" }
    assert location
    assert_equal 2, location.fetch("count")
    assert_equal "Traverse City, Michigan", location.fetch("title")
    assert_includes location.fetch("location_url"), "/locations/"
    assert_equal 2, location.fetch("preview_urls").size
    assert_equal 3, payload.fetch("total")
  end

  test "clustered location marker links to an existing location page" do
    first = attached_photo(title: "West edge")
    second = attached_photo(title: "East edge")
    geotag(first, latitude: 44.701, longitude: -85.301)
    geotag(second, latitude: 44.789, longitude: -85.389)

    get map_markers_path(north: 45, south: 44, east: -85, west: -86, zoom: 10)

    assert_response :success
    payload = JSON.parse(response.body)
    location = payload.fetch("markers").find { |marker| marker.fetch("type") == "location" }
    assert location
    assert_equal 2, location.fetch("count")

    get location.fetch("location_url")

    assert_response :success
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
    assert_equal photo_path(trip_photo), marker.fetch("photo_url")
    assert_equal map_path(album_id: trip.id), marker.fetch("return_to")
  end

  test "map accepts initial bounds" do
    photo = attached_photo(title: "Bounded overlook")
    geotag(photo, latitude: 44.7622, longitude: -85.5980)

    get map_path(north: 45, south: 44, east: -85, west: -86)

    assert_response :success
    assert_select "[data-controller='google-map'][data-google-map-initial-north-value='45.0']"
    assert_select "[data-google-map-initial-south-value='44.0']"
    assert_select "[data-google-map-initial-east-value='-85.0']"
    assert_select "[data-google-map-initial-west-value='-86.0']"
  end

  test "map falls back to demo map id" do
    ENV["GOOGLE_MAPS_MAP_ID"] = nil
    photo = attached_photo(title: "Demo map id overlook")
    geotag(photo, latitude: 44.7622, longitude: -85.5980)

    get map_path

    assert_response :success
    assert_select "[data-controller='google-map'][data-google-map-map-id-value='DEMO_MAP_ID']"
  end

  test "invited viewer sees shared private geotagged photos but not unshared or locked photos" do
    album = @owner.photo_albums.create!(title: "Shared map", source: "manual")
    public_photo = attached_photo(title: "Public overlook")
    public_photo.publish!
    geotag(public_photo, latitude: 44.7622, longitude: -85.5980)
    shared_photo = attached_photo(title: "Shared private driveway")
    geotag(shared_photo, latitude: 45.0, longitude: -86.0)
    private_photo = attached_photo(title: "Unshared private driveway")
    geotag(private_photo, latitude: 45.1, longitude: -86.1)
    locked_photo = attached_photo(title: "Locked overlook")
    locked_photo.restrict!
    geotag(locked_photo, latitude: 45.5, longitude: -86.5)
    album.photos << [ shared_photo, locked_photo ]
    album.photo_album_shares.create!(user: users(:two), shared_by: @owner)

    delete sign_out_path
    sign_in_as(users(:two))

    get map_path

    assert_response :success

    get map_markers_path(north: 46, south: 44, east: -84, west: -87)

    assert_response :success
    payload = JSON.parse(response.body)
    marker_titles = payload.fetch("markers").map { |marker| marker.fetch("title") }
    assert_equal 2, payload.fetch("total")
    assert_includes marker_titles, "Public overlook"
    assert_includes marker_titles, "Shared private driveway"
    refute_includes marker_titles, "Unshared private driveway"
    refute_includes marker_titles, "Locked overlook"
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

  def location_id_for(photo)
    metadata = photo.metadata
    PhotoLocation.id_for(
      (metadata.latitude.to_f / PhotoLocation::CELL_SIZE).floor,
      (metadata.longitude.to_f / PhotoLocation::CELL_SIZE).floor
    )
  end

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
