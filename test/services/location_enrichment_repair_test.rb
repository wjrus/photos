require "test_helper"

class LocationEnrichmentRepairTest < ActiveSupport::TestCase
  setup do
    @rows = []
  end

  test "localizes each saved place once and keeps photo identity coordinates and old aliases" do
    first = photo(latitude: 56.95, longitude: 24.1)
    second = photo(latitude: 56.95, longitude: 24.1)
    place = PhotoPlace.create!(identity_key: "google:riga", provider: "google", provider_place_id: "riga", name: "Riga", place_type: "locality", latitude: 56.95, longitude: 24.1,
      map_region_key: "old-riga-key", map_region_name: "Riga")
    [ first, second ].each { |metadata| metadata.update!(photo_place: place) }
    # Legacy manual metadata with no assigned place must not poison a NOT IN query.
    photo(latitude: 1, longitude: 1).update!(raw: { "manual_location" => { "source" => "owner", "address" => "Owner correction" } })
    before = @rows.map { |row| [ row.photo_id, row.photo_place_id, row.latitude, row.longitude ] }
    calls = 0
    fake = Object.new
    fake.define_singleton_method(:localize) do |**_options|
      calls += 1
      { identity_key: "google:riga", name: "Rīga", names: [ "Latvija", "Rīga" ], place_type: "locality",
        map_region_key: "google-locality:v1:riga", map_region_name: "Rīga",
        raw: { "native_name_version" => LocationNativeGeocoder::VERSION, "source" => "google_geocoding_v4" } }
    end

    with_geocoder(fake) { assert_equal "complete", LocationEnrichmentRepair.run!(limit: 10)[:progress].fetch("state") }

    assert_equal 1, calls
    assert_equal "Rīga", place.reload.name
    assert_includes place.names, "Riga"
    assert_includes place.names, "Latvija"
    assert_includes place.raw["previous_map_region_ids"], PhotoLocationArea.id_for_region("old-riga-key")
    assert_equal before, @rows.map { |row| row.reload; [ row.photo_id, row.photo_place_id, row.latitude, row.longitude ] }
    with_geocoder(fake) { LocationEnrichmentRepair.run!(limit: 10) }
    assert_equal 1, calls
  end

  test "manual places and owner legacy corrections are not localized or reassigned" do
    metadata = photo(latitude: 40, longitude: -80)
    place = PhotoPlace.create!(identity_key: "google:manual", provider: "google", provider_place_id: "manual", name: "Owner address", place_type: "premise", latitude: 40, longitude: -80)
    metadata.update!(photo_place: place, location_source: "manual")
    photo(latitude: 41, longitude: -81).update!(raw: { "manual_location" => { "source" => "owner" } })
    fake = Object.new
    fake.define_singleton_method(:localize) { |**_options| raise "Must not call Google for manual data" }

    with_geocoder(fake) { assert_equal "complete", LocationEnrichmentRepair.run!(limit: 10)[:progress].fetch("state") }
    assert_equal "Owner address", place.reload.name
    assert_equal place.id, metadata.reload.photo_place_id
  end

  test "unavailable provider identities are reported without blocking other places or being retried indefinitely" do
    metadata = photo(latitude: 40, longitude: -80)
    place = PhotoPlace.create!(identity_key: "google:gone", provider: "google", provider_place_id: "gone", name: "Saved old name", place_type: "locality", latitude: 40, longitude: -80)
    metadata.update!(photo_place: place)
    fake = Object.new
    fake.define_singleton_method(:localize) { |**_options| nil }

    status = with_geocoder(fake) { LocationEnrichmentRepair.run!(limit: 10) }
    assert_equal "complete", status[:progress].fetch("state")
    assert_equal 1, status[:unresolved_named_places]
    assert_equal 0, status[:named_places_remaining]
    assert_equal "Saved old name", place.reload.name
  end

  test "a requested natural area labels only automatic coordinate photos inside actual provider bounds and keeps GPS" do
    inside = photo(latitude: 64.63, longitude: -19.30, coordinate: true)
    outside = photo(latitude: 64.70, longitude: -19.30, coordinate: true)
    manual = photo(latitude: 64.64, longitude: -19.31, coordinate: true)
    manual.update!(location_source: "manual")
    before = @rows.map { |row| [ row.latitude, row.longitude ] }
    fake = Object.new
    result = area_result
    fake.define_singleton_method(:named_area) { |query:| result }

    with_geocoder(fake) { LocationEnrichmentRepair.run!(limit: 1, area_query: "Kerlingarfjöll, Iceland", country_code: "IS") }
    assert_equal "Kerlingarfjöll", inside.reload.photo_place.name
    assert_equal "natural_feature", inside.photo_place.place_type
    assert_equal "coordinate", outside.reload.photo_place.place_type
    assert_equal "manual", manual.reload.location_source
    assert_equal "coordinate", manual.photo_place.place_type
    assert_equal before, @rows.map { |row| row.reload; [ row.latitude, row.longitude ] }
  end

  test "viewport boxes never stand in for actual natural-feature bounds" do
    inside = photo(latitude: 64.63, longitude: -19.30, coordinate: true)
    fake = Object.new
    result = area_result
    result[:raw]["geometry"]["viewport"] = result[:raw]["geometry"].delete("bounds")
    fake.define_singleton_method(:named_area) { |query:| result }

    assert_raises(LocationNativeGeocoder::LookupError) do
      with_geocoder(fake) { LocationEnrichmentRepair.run!(limit: 1, area_query: "Kerlingarfjöll, Iceland", country_code: "IS") }
    end
    assert_equal "coordinate", inside.reload.photo_place.place_type
  end

  test "coordinate repairs mark unsuccessful name searches and do not repeat them on resume" do
    metadata = photo(latitude: 44, longitude: -80, coordinate: true)
    previous_place_id = metadata.photo_place_id
    calls = 0
    fake = Object.new
    fake.define_singleton_method(:geocode) do |**_options|
      calls += 1
      { name: "44.000000, -80.000000", place_type: "coordinate", names: [], raw: { "native_name_version" => LocationNativeGeocoder::VERSION } }
    end
    original = LocationLandmarkLookup.method(:new)
    nearby = Object.new
    nearby.define_singleton_method(:geocode) { |**_options| nil }
    LocationLandmarkLookup.define_singleton_method(:new) { |**_options| nearby }

    status = with_geocoder(fake) { LocationEnrichmentRepair.run!(limit: 10) }
    assert_equal "complete", status[:progress].fetch("state")
    assert_equal 1, status[:unresolved_coordinate_photos]
    assert_equal 0, status[:coordinate_photos_remaining]
    assert_equal previous_place_id, metadata.reload.photo_place_id
    assert_equal [ 44, -80 ], [ metadata.latitude, metadata.longitude ]
    with_geocoder(fake) { LocationEnrichmentRepair.run!(limit: 10) }
    assert_equal 1, calls
  ensure
    LocationLandmarkLookup.define_singleton_method(:new, original) if original
  end

  private

  def photo(latitude:, longitude:, coordinate: false)
    now = Time.current
    id = Photo.insert_all!([ { owner_id: users(:one).id, title: "Synthetic repair photo", created_at: now, updated_at: now } ]).rows.flatten.sole
    metadata = PhotoMetadata.create!(photo_id: id, latitude: latitude, longitude: longitude, location_source: "automatic", raw: {})
    if coordinate
      place = PhotoPlace.from_geocode!(result: { name: "Coordinate", place_type: "coordinate" }, latitude: latitude, longitude: longitude)
      metadata.update!(photo_place: place)
    end
    @rows << metadata
    metadata
  end

  def area_result
    { identity_key: "google:kerlingarfjoll", name: "Kerlingarfjöll", names: [ "Ísland" ], provider: "google", provider_place_id: "kerlingarfjoll", place_type: "natural_feature",
      raw: { "native_name_version" => LocationNativeGeocoder::VERSION, "source" => "google_geocoding_v4",
        "address_components" => [ { "long_name" => "Ísland", "short_name" => "IS", "types" => [ "country" ] } ],
        "geometry" => { "location" => { "lat" => 64.63, "lng" => -19.30 }, "bounds" => { "southwest" => { "lat" => 64.60, "lng" => -19.34 }, "northeast" => { "lat" => 64.65, "lng" => -19.20 } } } } }
  end

  def with_geocoder(fake)
    original = LocationReverseGeocoder.method(:new)
    LocationReverseGeocoder.define_singleton_method(:new) { |**_options| fake }
    yield
  ensure
    LocationReverseGeocoder.define_singleton_method(:new, original)
  end
end
