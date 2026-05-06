require "test_helper"

class LocationsControllerTest < ActionDispatch::IntegrationTest
  setup do
    OmniAuth.config.test_mode = true
    @owner = users(:one)
    @google_maps_api_key = ENV["GOOGLE_MAPS_EMBED_API_KEY"]
    Rails.cache.clear
    sign_in_as(@owner)
  end

  teardown do
    ENV["GOOGLE_MAPS_EMBED_API_KEY"] = @google_maps_api_key
    OmniAuth.config.mock_auth[:google_oauth2] = nil
    OmniAuth.config.test_mode = false
  end

  test "owner can browse photo locations" do
    photo = attached_photo(title: "Downtown")
    geotag(photo, latitude: 44.7622, longitude: -85.5980)
    PhotoLocationPlace.create!(
      location_id: location_id_for(photo),
      name: "Traverse City, Michigan"
    )

    get locations_path

    assert_response :success
    assert_includes response.body, "Locations"
    assert_includes response.body, "Traverse City, Michigan"
    assert_includes response.body, "1 photo location"
    assert_includes response.body, "1 photo"
    assert_select "a[href='#{location_path(PhotoLocation.place_id_for_name("Traverse City, Michigan"))}']"
  end

  test "locations index groups cells with the same place name" do
    first = attached_photo(title: "First place cell")
    geotag(first, latitude: 44.7622, longitude: -85.5980)
    second = attached_photo(title: "Second place cell")
    geotag(second, latitude: 44.8022, longitude: -85.6380)
    place_name = "Traverse City, Michigan"

    [ first, second ].each do |photo|
      PhotoLocationPlace.create!(
        location_id: location_id_for(photo),
        name: place_name
      )
    end

    get locations_path

    assert_response :success
    assert_includes response.body, "1 photo location"
    assert_includes response.body, "2 photos"
    assert_select "a[href='#{location_path(PhotoLocation.place_id_for_name(place_name))}']"
  end

  test "locations index splits photo and video counts" do
    photo = attached_photo(title: "Place photo")
    geotag(photo, latitude: 44.7622, longitude: -85.5980)
    video = attached_video(title: "Place video")
    geotag(video, latitude: 44.7623, longitude: -85.5981)
    PhotoLocationPlace.create!(
      location_id: location_id_for(photo),
      name: "Traverse City, Michigan"
    )

    get locations_path

    assert_response :success
    assert_select "article", text: /Traverse City, Michigan.*1 photo, 1 video/m
  end

  test "locations index uses explicit location covers" do
    fallback = attached_photo(title: "Fallback cover")
    geotag(fallback, latitude: 44.7622, longitude: -85.5980)
    explicit = attached_video(title: "Explicit cover")
    explicit.video_preview.attach(
      io: File.open(Rails.root.join("public/icon.png")),
      filename: "explicit-cover.png",
      content_type: "image/png"
    )
    geotag(explicit, latitude: 44.7623, longitude: -85.5981)
    location_id = location_id_for(fallback)
    @owner.photo_location_covers.create!(location_id: location_id, cover_photo: explicit)

    get locations_path

    assert_response :success
    assert_select "img[alt='Explicit cover']"
  end

  test "place location page shows all matching location cells" do
    first = attached_photo(title: "First grouped place")
    geotag(first, latitude: 44.7622, longitude: -85.5980)
    second = attached_photo(title: "Second grouped place")
    geotag(second, latitude: 44.8022, longitude: -85.6380)
    outside = attached_photo(title: "Outside grouped place")
    geotag(outside, latitude: 45.5, longitude: -86.5)
    place_name = "Traverse City, Michigan"

    [ first, second ].each do |photo|
      PhotoLocationPlace.create!(
        location_id: location_id_for(photo),
        name: place_name
      )
    end

    get location_path(PhotoLocation.place_id_for_name(place_name))

    assert_response :success
    assert_includes response.body, "First grouped place"
    assert_includes response.body, "Second grouped place"
    refute_includes response.body, "Outside grouped place"
  end

  test "locations index does not bulk enqueue missing geocodes" do
    ENV["GOOGLE_MAPS_EMBED_API_KEY"] = "test-key"
    photo = attached_photo(title: "Ungocoded")
    geotag(photo, latitude: 44.7622, longitude: -85.5980)

    assert_no_enqueued_jobs only: GeocodePhotoLocationJob do
      get locations_path
    end

    assert_response :success
  end

  test "location page shows matching photos as a stream" do
    inside = attached_photo(title: "Inside location")
    geotag(inside, latitude: 44.7622, longitude: -85.5980)
    PhotoLocationPlace.create!(
      location_id: location_id_for(inside),
      name: "Traverse City, Michigan"
    )
    outside = attached_photo(title: "Outside location")
    geotag(outside, latitude: 45.5, longitude: -86.5)

    get location_path(location_id_for(inside))

    assert_response :success
    assert_includes response.body, "Traverse City, Michigan"
    assert_includes response.body, "Inside location"
    refute_includes response.body, "Outside location"
    assert_select "[data-controller~='stream-state']"
    assert_select "a[href='#{photo_path(inside)}'][data-photo-return-to='#{location_path(location_id_for(inside))}']"
  end

  test "location page renders as a flat grid without date groups" do
    inside = attached_photo(title: "Inside location")
    geotag(inside, latitude: 44.7622, longitude: -85.5980)

    get location_path(location_id_for(inside))

    assert_response :success
    assert_select ".photo-flat-pages"
    assert_select ".photo-flat-grid"
    assert_select "[data-stream-date-group-key]", false
  end

  test "location infinite scroll pages do not render date groups" do
    inside = attached_photo(title: "Inside location")
    geotag(inside, latitude: 44.7622, longitude: -85.5980)

    get location_path(location_id_for(inside), stream_page: 1)

    assert_response :success
    assert_select ".photo-flat-pages", false
    assert_select ".photo-flat-grid"
    assert_select "[data-stream-date-group-key]", false
  end

  test "location page splits photo and video counts" do
    photo = attached_photo(title: "Location photo")
    geotag(photo, latitude: 44.7622, longitude: -85.5980)
    video = attached_video(title: "Location video")
    geotag(video, latitude: 44.7623, longitude: -85.5981)

    get location_path(location_id_for(photo))

    assert_response :success
    assert_select "p", text: /1 photo, 1 video/
  end

  test "location detail may enqueue only its missing geocode" do
    ENV["GOOGLE_MAPS_EMBED_API_KEY"] = "test-key"
    inside = attached_photo(title: "Specific ungeocoded")
    geotag(inside, latitude: 44.7622, longitude: -85.5980)

    assert_enqueued_with(job: GeocodePhotoLocationJob) do
      get location_path(location_id_for(inside))
    end

    assert_response :success
  end

  test "anonymous viewer cannot browse locations" do
    delete sign_out_path

    get locations_path

    assert_redirected_to root_path
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

  def attached_video(title:)
    photo = @owner.photos.new(title: title)
    photo.original.attach(
      io: StringIO.new("fake mp4 bytes"),
      filename: "#{title.parameterize}.mp4",
      content_type: "video/mp4"
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
