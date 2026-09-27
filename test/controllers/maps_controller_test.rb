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
    Rails.cache.clear
    sign_in_as(@owner)
  end

  teardown do
    ENV["PHOTOS_TRUSTED_VIEWER_EMAILS"] = @trusted_viewer_emails
    ENV["GOOGLE_MAPS_EMBED_API_KEY"] = @google_maps_api_key
    ENV["GOOGLE_MAPS_MAP_ID"] = @google_maps_map_id
    Rails.cache.clear
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
    assert_includes response.body, "1 geotagged photo"
    assert_includes response.body, "All photos"
    assert_includes response.body, "All locations"
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

  test "map counts and markers require both coordinates while retaining zero coordinates" do
    complete = attached_photo(title: "Both coordinates")
    latitude_only = attached_photo(title: "Latitude only")
    longitude_only = attached_photo(title: "Longitude only")
    geotag(complete, latitude: 0, longitude: 0)
    geotag(latitude_only, latitude: 0, longitude: nil)
    geotag(longitude_only, latitude: nil, longitude: 0)

    get map_path
    assert_response :success
    assert_includes response.body, "1 geotagged photo"

    get map_markers_path(zoom: 12)
    assert_response :success
    assert_equal 1, response.parsed_body.fetch("total")
    assert_equal complete.id, response.parsed_body.fetch("markers").sole.fetch("id")
  end

  test "markers groups nearby photos into locations at lower zoom levels" do
    first = attached_photo(title: "First overlook")
    second = attached_photo(title: "Second overlook")
    far = attached_photo(title: "Far overlook")
    geotag(first, latitude: 44.7622, longitude: -85.5980)
    geotag(second, latitude: 44.7630, longitude: -85.5970)
    geotag(far, latitude: 45.5, longitude: -86.5)
    place = assign_place([ first, second ], name: "Traverse City, Michigan")

    get map_markers_path(north: 46, south: 44, east: -84, west: -87, zoom: 10)

    assert_response :success
    payload = JSON.parse(response.body)
    location = payload.fetch("markers").find { |marker| marker.fetch("type") == "location" }
    assert location
    assert_equal 2, location.fetch("count")
    assert_equal "Traverse City, Michigan", location.fetch("title")
    assert_equal location_path(PhotoLocation.id_for_place(place)), location.fetch("location_url")
    assert_equal 2, location.fetch("preview_urls").size
    assert_equal 3, payload.fetch("total")
  end

  test "map location cells and filtered marker links preserve exact boundary photos" do
    first = attached_photo(title: "Before boundary")
    boundary = attached_photo(title: "At boundary")
    outside = attached_photo(title: "After boundary")
    geotag(first, latitude: "44.774999", longitude: "-85.575000")
    geotag(boundary, latitude: "44.775000", longitude: "-85.575000")
    geotag(outside, latitude: "44.775001", longitude: "-85.575000")
    place = assign_place([ first, boundary ], name: "Boundary town")

    get map_markers_path(zoom: 12)
    assert_response :success
    cluster = response.parsed_body.fetch("markers").find { |marker| marker.fetch("type") == "location" }
    assert_equal 2, cluster.fetch("count")
    assert_equal "Boundary town", cluster.fetch("title")
    assert_equal location_path(PhotoLocation.id_for_place(place)), cluster.fetch("location_url")

    get cluster.fetch("location_url")
    assert_response :success
    assert_select "[data-photo-id='#{first.id}']"
    assert_select "[data-photo-id='#{boundary.id}']"
    assert_select "[data-photo-id='#{outside.id}']", count: 0

    get map_markers_path(zoom: 12, location_id: PhotoLocation.id_for_place(place))
    assert_response :success
    assert_equal 2, response.parsed_body.fetch("total")
    assert_equal 2, response.parsed_body.fetch("markers").sole.fetch("count")
  end

  test "low zoom combines a qualified metro region across cells and higher zoom restores exact places" do
    previous_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    first, second, outside = london_region_photos
    marker_params = { north: 52, south: 51, east: 0.5, west: -0.6 }

    [ 9, 10 ].each do |zoom|
      get map_markers_path(**marker_params, zoom: zoom)

      assert_response :success
      assert_equal 3, response.parsed_body.fetch("total")
      markers = response.parsed_body.fetch("markers")
      assert_equal 2, markers.size
      london = markers.find { |marker| marker.fetch("type") == "location" }
      assert_equal "London", london.fetch("title")
      assert_equal 2, london.fetch("count")
      assert_equal [ stream_photo_path(first), stream_photo_path(second) ].sort, london.fetch("preview_urls").sort
      assert_equal 11, london.fetch("zoom_to")
      refute london.key?("location_url")
      assert_equal outside.id, markers.find { |marker| marker.fetch("type") == "photo" }.fetch("id")
    end

    # 10 and 10.5 use the same spatial size but different region-grouping modes.
    [ 10.5, 12 ].each do |zoom|
      get map_markers_path(**marker_params, zoom: zoom)

      assert_response :success
      markers = response.parsed_body.fetch("markers")
      assert_equal [ first.id, second.id, outside.id ].sort, markers.map { |marker| marker.fetch("id") }.sort
      assert markers.all? { |marker| marker.fetch("type") == "photo" }
    end

    get location_path(PhotoLocation.id_for_place(first.metadata.photo_place))
    assert_response :success
    assert_select "[data-photo-id='#{first.id}']"
    assert_select "[data-photo-id='#{second.id}']", count: 0
    assert_select "[data-photo-id='#{outside.id}']", count: 0
  ensure
    Rails.cache = previous_cache
  end

  test "regional rollups honor the current viewport and album filter" do
    first, second, = london_region_photos

    get map_markers_path(zoom: 9, north: 51.52, south: 51.49, east: -0.1, west: -0.2)
    assert_response :success
    assert_equal 1, response.parsed_body.fetch("total")
    assert_equal first.id, response.parsed_body.fetch("markers").sole.fetch("id")

    album = @owner.photo_albums.create!(title: "One borough", source: "manual")
    album.photos << second
    get map_markers_path(zoom: 9, album_id: album.id)
    assert_response :success
    assert_equal 1, response.parsed_body.fetch("total")
    assert_equal second.id, response.parsed_body.fetch("markers").sole.fetch("id")
  end

  test "a regional marker zooms instead of linking to the only precise place currently represented" do
    photos = [ "Venue first", "Venue second" ].map do |title|
      attached_photo(title: title).tap { |photo| geotag(photo, latitude: 51.501, longitude: -0.141) }
    end
    place = assign_place(photos, name: "Specific London venue")
    place.update!(map_region_key: "test:gb:greater-london", map_region_name: "London")

    get map_markers_path(zoom: 9)
    assert_response :success
    marker = response.parsed_body.fetch("markers").sole
    assert_equal "London", marker.fetch("title")
    assert_equal 2, marker.fetch("count")
    assert_equal 11, marker.fetch("zoom_to")
    refute marker.key?("location_url")

    get map_markers_path(zoom: 12)
    assert_response :success
    marker = response.parsed_body.fetch("markers").sole
    assert_equal place.name, marker.fetch("title")
    assert_equal location_path(PhotoLocation.id_for_place(place)), marker.fetch("location_url")
  end

  test "region names never substitute for missing qualified region identities" do
    photos = [ [ 51.501, -0.141 ], [ 51.462, -0.302 ] ].map.with_index do |(latitude, longitude), index|
      attached_photo(title: "Unqualified photo #{index}").tap do |photo|
        geotag(photo, latitude: latitude, longitude: longitude)
        assign_place([ photo ], name: "London")
        PhotoLocationPlace.create!(location_id: location_id_for(photo), name: "London")
      end
    end

    get map_markers_path(zoom: 9)

    assert_response :success
    assert_equal photos.map(&:id).sort, response.parsed_body.fetch("markers").map { |marker| marker.fetch("id") }.sort
  end

  test "invited viewers see only authorized region members and revocation immediately changes the rollup" do
    previous_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    first, second, hidden = london_region_photos
    hidden.metadata.photo_place.update!(map_region_key: "test:gb:greater-london", map_region_name: "London")
    first.publish!
    grant = second.photo_people_tags.create!(user: users(:two), tagged_by: @owner)
    delete sign_out_path
    sign_in_as(users(:two))

    get map_markers_path(zoom: 9)
    assert_response :success
    assert_equal 2, response.parsed_body.fetch("total")
    marker = response.parsed_body.fetch("markers").sole
    assert_equal "London", marker.fetch("title")
    assert_equal 2, marker.fetch("count")
    assert_equal [ stream_photo_path(first), stream_photo_path(second) ].sort, marker.fetch("preview_urls").sort

    grant.destroy!
    get map_markers_path(zoom: 9)
    assert_response :success
    assert_equal 1, response.parsed_body.fetch("total")
    assert_equal first.id, response.parsed_body.fetch("markers").sole.fetch("id")
  ensure
    Rails.cache = previous_cache
  end

  test "map previews use stream thumbnails without loading original blobs or full EXIF" do
    first = attached_photo(title: "First thumbnail")
    second = attached_photo(title: "Second thumbnail")
    single = attached_photo(title: "Single thumbnail")
    geotag(first, latitude: 40.001, longitude: -80.001)
    geotag(second, latitude: 40.002, longitude: -80.002)
    geotag(single, latitude: 41, longitude: -81)
    instantiated_blobs = 0
    queries = []
    records = lambda do |event|
      instantiated_blobs += event.payload[:record_count] if event.payload[:class_name] == "ActiveStorage::Blob"
    end
    sql = ->(event) { queries << event.payload[:sql] unless event.payload[:name] == "SCHEMA" }

    ActiveSupport::Notifications.subscribed(records, "instantiation.active_record") do
      ActiveSupport::Notifications.subscribed(sql, "sql.active_record") do
        get map_markers_path(zoom: 10)
      end
    end

    assert_response :success
    markers = response.parsed_body.fetch("markers")
    cluster = markers.find { |marker| marker.fetch("type") == "location" }
    single_marker = markers.find { |marker| marker.fetch("type") == "photo" }
    assert_equal [ stream_photo_path(first), stream_photo_path(second) ].sort, cluster.fetch("preview_urls").sort
    assert_equal stream_photo_path(single), single_marker.fetch("media_url")
    assert_equal 0, instantiated_blobs
    assert_empty queries.grep(/SELECT "photo_metadata"\.\*/)
  end

  test "cached location markers do not recalculate selected location summaries" do
    previous_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    photo = attached_photo(title: "Cached location")
    geotag(photo, latitude: 40, longitude: -80)
    place = assign_place([ photo ], name: "Synthetic place")

    [ location_id_for(photo), PhotoLocation.id_for_place(place) ].each do |location_id|
      get map_markers_path(location_id: location_id)
      assert_response :success
      expected_payload = response.parsed_body
      queries = []
      subscriber = ->(event) { queries << event.payload[:sql] unless event.payload[:name] == "SCHEMA" }

      ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") do
        get map_markers_path(location_id: location_id)
      end

      assert_response :success
      assert_equal expected_payload, response.parsed_body
      photo_aggregates = queries.select { |sql| sql.include?('FROM "photos"') && sql.match?(/COUNT\(|ARRAY_AGG\(/) }
      assert_empty photo_aggregates, "A cache hit should not aggregate the selected location again"
    end
  ensure
    Rails.cache = previous_cache
  end

  test "map video previews use the authorized thumbnail endpoint and omit pending previews" do
    ready, pending = [ "Ready clip", "Pending clip" ].map do |title|
      @owner.photos.create!(
        title: title,
        original: { io: StringIO.new("synthetic video"), filename: "clip.mp4", content_type: "video/mp4" }
      ).tap { |photo| geotag(photo, latitude: 40, longitude: -80) }
    end
    ready.video_preview.attach(io: File.open(Rails.root.join("public/icon.png")), filename: "poster.jpg", content_type: "image/jpeg")

    get map_markers_path(zoom: 10), headers: { "Accept" => "application/json" }

    assert_response :success
    cluster = response.parsed_body.fetch("markers").sole
    assert_equal 2, cluster.fetch("count")
    assert_equal [ stream_photo_path(ready) ], cluster.fetch("preview_urls")
    get stream_photo_path(ready)
    assert_response :redirect
    assert_includes response.headers.fetch("Location"), "poster.jpg"
    get stream_photo_path(pending)
    assert_response :not_found
  end

  test "a mixed coordinate cluster cannot link only to its representative location" do
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
    assert_equal "2 nearby locations", location.fetch("title")
    refute location.key?("location_url")
  end

  test "different places in one coordinate cell keep separate identities in clusters and map filters" do
    neighbor = attached_photo(title: "Neighbor cluster item")
    representative = attached_photo(title: "Named cluster item")
    geotag(neighbor, latitude: 44.7622, longitude: -85.5980)
    geotag(representative, latitude: 44.7630, longitude: -85.5970)
    neighbor_place = assign_place([ neighbor ], name: "Shared display name")
    representative_place = assign_place([ representative ], name: "Shared display name")

    get map_markers_path(north: 45, south: 44, east: -85, west: -86, zoom: 12)

    assert_response :success
    payload = JSON.parse(response.body)
    location = payload.fetch("markers").find { |marker| marker.fetch("type") == "location" }
    assert_equal "2 nearby locations", location.fetch("title")
    refute location.key?("location_url")

    get map_path
    assert_response :success
    [ [ neighbor_place, neighbor ], [ representative_place, representative ] ].each do |place, photo|
      coordinates = PhotoLocation.title_for(photo.metadata.latitude, photo.metadata.longitude)
      assert_select "select#location_id option[value='#{PhotoLocation.id_for_place(place)}']", text: "Shared display name (#{coordinates})"
    end

    get map_markers_path(location_id: PhotoLocation.id_for_place(neighbor_place), zoom: 12)
    assert_response :success
    assert_equal 1, response.parsed_body.fetch("total")
    assert_equal neighbor.id, response.parsed_body.fetch("markers").sole.fetch("id")

    get map_path(location_id: location_id_for(neighbor))
    assert_response :success
    assert_select "select#location_id option[selected][value='#{location_id_for(neighbor)}']", text: /44\.7626, -85\.5975/
    assert_includes response.body, "2 geotagged photos"
  end

  test "one place spanning coordinate cells links every cluster member to that exact place" do
    first = attached_photo(title: "Same place west")
    second = attached_photo(title: "Same place east")
    outsider = attached_photo(title: "Different nearby place")
    geotag(first, latitude: 44.701, longitude: -85.301)
    geotag(second, latitude: 44.789, longitude: -85.389)
    geotag(outsider, latitude: 45.0, longitude: -86.0)
    place = assign_place([ first, second ], name: "One actual place")
    assign_place([ outsider ], name: "One actual place")

    get map_markers_path(north: 45, south: 44, east: -85, west: -86, zoom: 10)

    assert_response :success
    marker = response.parsed_body.fetch("markers").find { |item| item.fetch("type") == "location" }
    assert_equal "One actual place", marker.fetch("title")
    assert_equal location_path(PhotoLocation.id_for_place(place)), marker.fetch("location_url")
    get marker.fetch("location_url")
    assert_response :success
    assert_select "[data-photo-id='#{first.id}']"
    assert_select "[data-photo-id='#{second.id}']"
    assert_select "[data-photo-id='#{outsider.id}']", count: 0
  end

  test "cluster identity considers members outside its six preview photos" do
    photos = 7.times.map do |index|
      attached_photo(title: "Cluster member #{index}").tap do |photo|
        geotag(photo, latitude: 44.7622, longitude: -85.5980)
        photo.update_columns(created_at: Time.zone.local(2026, 1, index + 1))
      end
    end
    assign_place(photos.drop(1), name: "Preview place")
    assign_place([ photos.first ], name: "Older different place")

    get map_markers_path(zoom: 12)

    assert_response :success
    marker = response.parsed_body.fetch("markers").sole
    assert_equal 7, marker.fetch("count")
    assert_equal 6, marker.fetch("preview_urls").size
    assert_equal "2 nearby locations", marker.fetch("title")
    refute marker.key?("location_url")
  end

  test "unresolved coordinates do not inherit a legacy cell place name" do
    first = attached_photo(title: "Unresolved first")
    second = attached_photo(title: "Unresolved second")
    geotag(first, latitude: 44.7622, longitude: -85.5980)
    geotag(second, latitude: 44.7630, longitude: -85.5970)
    PhotoLocationPlace.create!(location_id: location_id_for(first), name: "Legacy area name")

    get map_path
    assert_response :success
    assert_select "select#location_id option", text: "Legacy area name", count: 0
    assert_select "select#location_id option[value='#{PhotoLocation.id_for_area(location_id_for(first))}']"

    get map_markers_path(zoom: 12)
    assert_response :success
    marker = response.parsed_body.fetch("markers").sole
    refute_equal "Legacy area name", marker.fetch("title")
    assert_equal location_path(PhotoLocation.id_for_area(location_id_for(first))), marker.fetch("location_url")
  end

  test "an unresolved area filter and marker link exclude assigned places in the same cell" do
    unresolved = [ "Unresolved first", "Unresolved second" ].map { |title| attached_photo(title: title) }
    assigned = attached_photo(title: "Matched venue")
    [ *unresolved, assigned ].each { |photo| geotag(photo, latitude: 44.7622, longitude: -85.5980) }
    assign_place([ assigned ], name: "Nearby venue")
    area_id = PhotoLocation.id_for_area(location_id_for(assigned))

    get map_markers_path(location_id: area_id, zoom: 12)
    assert_response :success
    assert_equal 2, response.parsed_body.fetch("total")
    marker = response.parsed_body.fetch("markers").sole
    assert_equal location_path(area_id), marker.fetch("location_url")

    get marker.fetch("location_url")
    assert_response :success
    unresolved.each { |photo| assert_select "[data-photo-id='#{photo.id}']" }
    assert_select "[data-photo-id='#{assigned.id}']", count: 0

    get map_markers_path(location_id: location_id_for(assigned), zoom: 12)
    assert_response :success
    assert_equal 3, response.parsed_body.fetch("total")
    assert_equal "2 nearby locations", response.parsed_body.fetch("markers").sole.fetch("title")
    refute response.parsed_body.fetch("markers").sole.key?("location_url")
  end

  test "legacy named map links go through location disambiguation and ambiguous markers stay empty" do
    previous_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    first = attached_photo(title: "First old named place")
    second = attached_photo(title: "Second old named place")
    geotag(first, latitude: 44.7622, longitude: -85.5980)
    geotag(second, latitude: 45.0, longitude: -86.0)
    assign_place([ first ], name: "Duplicate place name")
    assign_place([ second ], name: "Duplicate place name")
    legacy_id = PhotoLocation.place_id_for_name("Duplicate place name")

    get map_path(location_id: legacy_id)
    assert_redirected_to location_path(legacy_id)

    get map_markers_path
    assert_response :success
    assert_equal 2, response.parsed_body.fetch("total")

    [ legacy_id, "invalid", "all", "place-id-999999999" ].each do |location_id|
      get map_markers_path(location_id: location_id)
      assert_response :success
      assert_equal 0, response.parsed_body.fetch("total")
      assert_empty response.parsed_body.fetch("markers")
    end
  ensure
    Rails.cache = previous_cache
  end

  test "unique legacy marker filters normalize their photo return path to the exact place" do
    photo = attached_photo(title: "Old unique named place")
    geotag(photo, latitude: 44.7622, longitude: -85.5980)
    place = assign_place([ photo ], name: "Unique legacy place")

    get map_markers_path(location_id: PhotoLocation.place_id_for_name(place.name))

    assert_response :success
    marker = response.parsed_body.fetch("markers").sole
    assert_equal map_path(location_id: PhotoLocation.id_for_place(place)), marker.fetch("return_to")
  end

  test "map markers refresh after location place names change" do
    previous_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    first = attached_photo(title: "Uncached first")
    second = attached_photo(title: "Uncached second")
    geotag(first, latitude: 44.701, longitude: -85.301)
    geotag(second, latitude: 44.789, longitude: -85.389)
    place = assign_place([ first, second ], name: "Original place")
    marker_params = { north: 45, south: 44, east: -85, west: -86, zoom: 10 }

    get map_markers_path(**marker_params)

    assert_response :success
    initial_payload = JSON.parse(response.body)
    initial_location = initial_payload.fetch("markers").find { |marker| marker.fetch("type") == "location" }
    refute_equal "Fresh Place Name", initial_location.fetch("title")

    place.update!(name: "Fresh Place Name")

    get map_markers_path(**marker_params)

    assert_response :success
    updated_payload = JSON.parse(response.body)
    updated_location = updated_payload.fetch("markers").find { |marker| marker.fetch("type") == "location" }
    assert_equal "Fresh Place Name", updated_location.fetch("title")
  ensure
    Rails.cache = previous_cache
  end

  test "cached markers refresh when a photo receives a different place assignment" do
    previous_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    first = attached_photo(title: "Assigned first")
    second = attached_photo(title: "Assigned second")
    [ first, second ].each { |photo| geotag(photo, latitude: 44.7622, longitude: -85.5980) }
    place = assign_place([ first, second ], name: "Original place")
    other_place = PhotoPlace.create!(identity_key: "test:#{SecureRandom.uuid}", name: "New separate place")

    get map_markers_path(zoom: 12)
    assert_response :success
    assert_equal location_path(PhotoLocation.id_for_place(place)), response.parsed_body.fetch("markers").sole.fetch("location_url")

    second.metadata.update!(photo_place: other_place, location_source: "automatic")
    get map_markers_path(zoom: 12)
    assert_response :success
    marker = response.parsed_body.fetch("markers").sole
    assert_equal "2 nearby locations", marker.fetch("title")
    refute marker.key?("location_url")
  ensure
    Rails.cache = previous_cache
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

  test "owner can focus map on a location and return to it" do
    inside = attached_photo(title: "Location map inside")
    outside = attached_photo(title: "Location map outside")
    geotag(inside, latitude: 44.7622, longitude: -85.5980)
    geotag(outside, latitude: 45.0, longitude: -86.0)
    location_id = location_id_for(inside)

    get map_path(location_id: location_id)

    assert_response :success
    assert_select "a[href='#{location_path(location_id)}']", { text: /Back to/, count: 0 }
    assert_select "option[selected][value='#{location_id}']"
    assert_select "[data-google-map-markers-url-value='#{map_markers_path(location_id: location_id)}']"

    get map_markers_path(location_id: location_id, north: 46, south: 44, east: -84, west: -87)

    assert_response :success
    payload = JSON.parse(response.body)
    marker_titles = payload.fetch("markers").map { |marker| marker.fetch("title") }
    assert_includes marker_titles, "Location map inside"
    refute_includes marker_titles, "Location map outside"
    marker = payload.fetch("markers").find { |candidate| candidate.fetch("title") == "Location map inside" }
    assert_equal map_path(location_id: location_id), marker.fetch("return_to")
  end

  test "map location filter is alphabetical" do
    zed = attached_photo(title: "Zed place")
    alpha = attached_photo(title: "Alpha place")
    geotag(zed, latitude: 45.0, longitude: -86.0)
    geotag(alpha, latitude: 44.7622, longitude: -85.5980)
    assign_place([ zed ], name: "Zed Point")
    assign_place([ alpha ], name: "Alpha Bay")

    get map_path

    assert_response :success
    location_options = css_select("select#location_id option").map(&:text)
    assert_equal [ "All locations", "Alpha Bay", "Zed Point" ], location_options
  end

  test "map can combine album and location filters" do
    album = @owner.photo_albums.create!(title: "Location album", source: "manual")
    inside_album = attached_photo(title: "Inside album location")
    outside_album = attached_photo(title: "Outside album location")
    inside_other = attached_photo(title: "Inside other album")
    geotag(inside_album, latitude: 44.7622, longitude: -85.5980)
    geotag(outside_album, latitude: 45.0, longitude: -86.0)
    geotag(inside_other, latitude: 44.7623, longitude: -85.5981)
    album.photos << [ inside_album, outside_album ]
    location_id = location_id_for(inside_album)

    get map_markers_path(album_id: album.id, location_id: location_id, north: 46, south: 44, east: -84, west: -87)

    assert_response :success
    payload = JSON.parse(response.body)
    marker_titles = payload.fetch("markers").map { |marker| marker.fetch("title") }
    assert_includes marker_titles, "Inside album location"
    refute_includes marker_titles, "Outside album location"
    refute_includes marker_titles, "Inside other album"
  end

  test "selected album initializes map around its photos" do
    trip = @owner.photo_albums.create!(title: "River trip", source: "manual")
    first = attached_photo(title: "Trip south")
    second = attached_photo(title: "Trip north")
    other = attached_photo(title: "Other map photo")
    geotag(first, latitude: 36.895894, longitude: -111.526942)
    geotag(second, latitude: 36.921856, longitude: -111.495014)
    geotag(other, latitude: 45.0, longitude: -86.0)
    trip.photos << [ first, second ]

    get map_path(album_id: trip.id)

    assert_response :success
    assert_select "[data-controller='google-map'][data-google-map-initial-north-value='36.961856']"
    assert_select "[data-controller='google-map'][data-google-map-initial-south-value='36.855894']"
    assert_select "[data-controller='google-map'][data-google-map-initial-east-value='-111.455014']"
    assert_select "[data-controller='google-map'][data-google-map-initial-west-value='-111.566942']"
  end

  test "map accepts initial bounds" do
    photo = attached_photo(title: "Bounded overlook")
    geotag(photo, latitude: 44.7622, longitude: -85.5980)

    get map_path(north: 45, south: 44, east: -85, west: -86)

    assert_response :success
    assert_select "[data-controller='google-map'][data-google-map-initial-north-value='45.000000']"
    assert_select "[data-google-map-initial-south-value='44.000000']"
    assert_select "[data-google-map-initial-east-value='-85.000000']"
    assert_select "[data-google-map-initial-west-value='-86.000000']"
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

  def london_region_photos
    [ [ "Westminster venue", 51.501, -0.141 ], [ "Western borough venue", 51.462, -0.302 ], [ "Outside metro namesake", 51.72, -0.34 ] ].map.with_index do |(title, latitude, longitude), index|
      attached_photo(title: title).tap do |photo|
        geotag(photo, latitude: latitude, longitude: longitude)
        place = assign_place([ photo ], name: title)
        place.update!(
          map_region_key: index == 2 ? "test:gb:other-county:london" : "test:gb:greater-london",
          map_region_name: "London"
        )
      end
    end
  end

  def assign_place(photos, name:)
    PhotoPlace.create!(identity_key: "test:#{SecureRandom.uuid}", name: name).tap do |place|
      photos.each { |photo| photo.metadata.update!(photo_place: place, location_source: "automatic") }
    end
  end

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
