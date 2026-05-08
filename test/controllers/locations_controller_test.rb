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

  test "location page can focus around a returned photo" do
    newer = attached_photo(title: "Newer location photo")
    target = attached_photo(title: "Returned location photo")
    older = attached_photo(title: "Older location photo")
    [ newer, target, older ].each do |photo|
      geotag(photo, latitude: 44.7622, longitude: -85.5980)
    end
    newer.update_columns(created_at: Time.zone.local(2026, 1, 3), updated_at: Time.zone.local(2026, 1, 3))
    target.update_columns(created_at: Time.zone.local(2026, 1, 2), updated_at: Time.zone.local(2026, 1, 2))
    older.update_columns(created_at: Time.zone.local(2026, 1, 1), updated_at: Time.zone.local(2026, 1, 1))
    location_id = location_id_for(target)

    get location_path(location_id, photo_id: target.id)

    assert_response :success
    assert_select "[data-stream-state-target-photo-id-value='#{target.id}']"
    assert_select "[data-photo-id='#{target.id}']"
    assert_select "[data-photo-id='#{older.id}']"
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

  test "location page renders timeline scoped to the location" do
    location_newer = attached_photo(title: "Location timeline newer")
    location_older = attached_photo(title: "Location timeline older")
    outside = attached_photo(title: "Outside location timeline")
    geotag(location_newer, latitude: 44.7622, longitude: -85.5980)
    geotag(location_older, latitude: 44.7623, longitude: -85.5981)
    geotag(outside, latitude: 45.5, longitude: -86.5)
    location_newer.update!(captured_at: Time.zone.local(2024, 5, 12, 10))
    location_older.update!(captured_at: Time.zone.local(2020, 2, 4, 10))
    outside.update!(captured_at: Time.zone.local(2018, 2, 4, 10))
    location_id = location_id_for(location_newer)

    get location_path(location_id)

    assert_response :success
    assert_select "nav[aria-label='Photo timeline'][data-controller='stream-timeline']"
    assert_select "button[aria-label*='Jump to May 2024'][data-stream-timeline-page-url-value^='#{location_path(location_id)}']"
    assert_select "button[aria-label*='Jump to February 2020'][data-stream-timeline-page-url-value^='#{location_path(location_id)}']"
    refute_includes response.body, "February 2018"

    get location_path(location_id, cursor: Photo.stream_cursor_before(Time.zone.local(2021, 1, 1)), stream_page: 1, timeline_page: 1)

    assert_response :success
    assert_includes response.body, location_older.title
    refute_includes response.body, location_newer.title
    refute_includes response.body, outside.title
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

  test "invited viewer browses shared private locations but not unshared or locked locations" do
    album = @owner.photo_albums.create!(title: "Shared places", source: "manual")
    shared_photo = attached_photo(title: "Shared private place")
    geotag(shared_photo, latitude: 44.7622, longitude: -85.5980)
    private_photo = attached_photo(title: "Unshared private place")
    geotag(private_photo, latitude: 45.0, longitude: -86.0)
    locked_photo = attached_photo(title: "Locked place")
    locked_photo.restrict!
    geotag(locked_photo, latitude: 45.5, longitude: -86.5)
    album.photos << [ shared_photo, locked_photo ]
    album.photo_album_shares.create!(user: users(:two), shared_by: @owner)
    delete sign_out_path
    sign_in_as(users(:two))

    get locations_path

    assert_response :success
    assert_includes response.body, "1 photo location"

    get location_path(location_id_for(shared_photo))

    assert_response :success
    assert_includes response.body, "Shared private place"

    get location_path(location_id_for(private_photo))

    assert_response :not_found

    get location_path(location_id_for(locked_photo))

    assert_response :not_found
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
