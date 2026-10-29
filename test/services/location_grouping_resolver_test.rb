require "test_helper"

class LocationGroupingResolverTest < ActiveSupport::TestCase
  setup do
    @catalog = LocationGroupingCatalog.new
    @catalog.observe([ city("canadian-falls", "Niagara Falls", "CA", "Canada", "ON", 43.09, -79.08),
      city("american-falls", "Niagara Falls", "US", "United States", "NY", 43.10, -79.03),
      city("fludir", "Flúðir", "IS", "Ísland", nil, 64.13, -20.32) ])
  end

  test "actual city IDs and nearby postal hints resolve to one city while international namesakes stay separate" do
    raw = geography("Niagara Falls", "CA", "Canada", state: "ON")
    one = resolve(raw.merge("native_locality" => { "place_id" => "canadian-falls", "name" => "Niagara Falls" }), latitude: 43.09, longitude: -79.08)
    two = resolve(raw, latitude: 43.095, longitude: -79.085)
    other = resolve(geography("Niagara Falls", "US", "United States", state: "NY"), latitude: 43.10, longitude: -79.03)

    assert_equal one[:map_region_key], two[:map_region_key]
    assert_match(/\Agoogle-locality:v1:/, two[:map_region_key])
    refute_equal one[:map_region_key], other[:map_region_key]
    assert_equal "Niagara Falls", two[:map_region_name]
  end

  test "distant postal towns cannot consume a landmark and canonical country names replace translated headings" do
    raw = geography("Flúðir", "IS", "Iceland")
    result = resolve(raw, latitude: 64.68, longitude: -19.30, name: "Ásgarður (Kerlingarfjöll)")

    assert_equal "Ásgarður (Kerlingarfjöll)", result[:map_region_name]
    assert_match(/\Agoogle-feature:v1:/, result[:map_region_key])
    assert_equal "Ísland", result.dig(:raw, "native_country", "name")
    assert_equal "Ísland", LocationGroupingCatalog.long_name(result[:raw]["address_components"].find { |component| component["types"].include?("country") })
    assert_equal raw["address_components"], result[:raw]["provider_address_components"]
    assert_equal "Iceland", raw["address_components"].last["long_name"], "Provider inputs are not mutated"
  end

  test "a requested display area includes its campsites without rewriting precise identities" do
    @catalog.add_area({ "place_id" => "mountains", "geometry" => { "location" => { "lat" => 64.64, "lng" => -19.25 } },
      "address_components" => geography(nil, "IS", "Ísland")["address_components"] }, name: "Kerlingarfjöll", radius: 16_000)
    first = resolve(geography("Flúðir", "IS", "Iceland"), latitude: 64.68, longitude: -19.30)
    second = resolve(geography("Kerlingafjöll", "IS", "Ísland"), latitude: 64.69, longitude: -19.31)
    distant = resolve(geography("Flúðir", "IS", "Ísland"), latitude: 64.13, longitude: -20.32)

    assert_equal "Kerlingarfjöll", first[:map_region_name]
    assert_equal first[:map_region_key], second[:map_region_key]
    refute_equal first[:map_region_key], distant[:map_region_key]
    assert_equal "google:precise-feature", first[:identity_key]
    assert_raises(ArgumentError) { @catalog.add_area({}, name: "Too broad", radius: 40_000) }
  end

  test "ambiguous nearby namesakes and conflicting state identities never get guessed" do
    @catalog.observe([ city("another-falls", "Niagara Falls", "CA", "Canada", "ON", 43.10, -79.10) ])
    ambiguous = resolve(geography("Niagara Falls", "CA", "Canada", state: "ON"), latitude: 43.095, longitude: -79.09)
    wrong_state = resolve(geography("Niagara Falls", "CA", "Canada", state: "BC"), latitude: 43.095, longitude: -79.09)

    assert_match(/\Agoogle-feature:v1:/, ambiguous[:map_region_key])
    assert_match(/\Agoogle-feature:v1:/, wrong_state[:map_region_key])
    assert_equal 0, AppSetting.where(key: LocationGroupingCatalog::SETTING_KEY).count, "Preview resolution does not persist its catalog"
  end

  test "native cached country names win over English Nearby responses and persistence survives reloads" do
    native = { "placeId" => "country-is", "types" => [ "country" ], "addressComponents" => [ { "longText" => "Ísland", "shortText" => "IS", "languageCode" => "is", "types" => [ "country" ] } ] }
    LocationGeocodingResponse.create!(request_key: "google-geocoding-v4/native-v1/synthetic", payload: { "results" => [ native ] })
    LocationGeocodingResponse.create!(request_key: "google-places-nearby/v2/en/synthetic", payload: [ { "addressComponents" => [ { "longText" => "Iceland", "shortText" => "IS", "types" => [ "country" ] } ] } ])
    catalog = LocationGroupingCatalog.from_cached_responses
    catalog.save!

    assert_equal "Ísland", LocationGroupingCatalog.load.country(geography(nil, "IS", "Iceland"))["name"]
    assert_equal "is", LocationGroupingCatalog.load.country(geography(nil, "IS", "Iceland"))["language_code"]
  end

  test "a grouping repair preserves manual corrections links covers and exact photo coordinates" do
    now = Time.current
    photo_id = Photo.insert_all!([ { owner_id: users(:one).id, title: "Synthetic manual correction", created_at: now, updated_at: now } ]).rows.flatten.sole
    raw = geography("Niagara Falls", "CA", "Canada", state: "ON")
    region = LocationMapRegion.for_result(raw)
    # Legacy rows with incomplete hierarchy used the saved-components SQL path.
    place = PhotoPlace.create!(identity_key: "google:owner-feature", name: "Owner-selected address", place_type: "premise", latitude: 43.095, longitude: -79.085, raw: raw, **region)
    metadata = PhotoMetadata.create!(photo_id: photo_id, photo_place: place, latitude: 43.095, longitude: -79.085, location_source: "manual", raw: { "manual_location" => { "source" => "owner" } })
    scope = Photo.where(id: photo_id).joins(:metadata)
    old_id = PhotoLocationArea.groups(scope).sole.id
    users(:one).photo_location_covers.create!(location_id: old_id, cover_photo_id: photo_id)
    before = metadata.attributes.deep_dup
    result = resolve(raw, latitude: place.latitude, longitude: place.longitude)
    result[:identity_key] = place.identity_key

    assert place.apply_grouping!(result, expected_raw: raw)
    assert_equal "Owner-selected address", place.reload.name
    assert_equal before, metadata.reload.attributes
    merged = PhotoLocationArea.groups(scope).sole
    assert_match(/\Acity-/, merged.id)
    assert_includes merged.location_ids, old_id
    assert_equal [ photo_id ], PhotoLocationArea.scope_for(scope, old_id).pluck(:id)
    refute place.apply_grouping!(result, expected_raw: raw), "Stale repair plans cannot replace a newer result"
  end

  test "manual legacy provider data can gain derived grouping without being marked as a native name update" do
    raw = geography("Niagara Falls", "CA", "Canada", state: "ON").except("native_name_version")
    input = { identity_key: "google:owner-feature", name: "Owner-selected address", place_type: "premise", raw: raw }
    assert_equal input, LocationGroupingResolver.resolve(input, latitude: 43.09, longitude: -79.08, catalog: @catalog)
    result = LocationGroupingResolver.resolve(input, latitude: 43.09, longitude: -79.08, catalog: @catalog, force: true)

    assert_equal "Owner-selected address", result[:name]
    assert_equal "Niagara Falls", result[:map_region_name]
    assert_nil result.dig(:raw, "native_name_version")
  end

  test "new observations merge with concurrently saved catalog entries" do
    first = LocationGroupingCatalog.load
    second = LocationGroupingCatalog.load
    first.observe([ city("one", "One Town", "US", "United States", "MI", 44, -85) ])
    second.observe([ city("two", "Two Town", "CA", "Canada", "ON", 45, -80) ])
    first.save!
    second.save!

    assert_equal %w[one two], LocationGroupingCatalog.load.data["cities"].keys.sort
    assert_equal %w[CA US], LocationGroupingCatalog.load.data["countries"].keys.sort
  end

  test "a missing provider state does not split a verified nearby UK town from its landmarks" do
    @catalog.observe([ city("edinburgh", "Edinburgh", "GB", "United Kingdom", nil, 55.95, -3.19) ])
    result = resolve(geography("Edinburgh", "GB", "United Kingdom", state: "Scotland"), latitude: 55.951, longitude: -3.191)

    assert_equal "Edinburgh", result[:map_region_name]
    assert_equal "google-locality:v1:#{Digest::SHA256.hexdigest('edinburgh')}", result[:map_region_key]
  end

  test "UK localities take precedence over postal towns with the same name or a broader postal address" do
    @catalog.observe([ city("edinburgh-city", "Edinburgh", "GB", "United Kingdom", "Scotland", 55.95, -3.19),
      city("edinburgh-postal", "Edinburgh", "GB", "United Kingdom", "Scotland", 55.95, -3.22).merge("types" => [ "postal_town" ],
        "address_components" => [ { "long_name" => "Edinburgh", "types" => [ "postal_town" ] }, *geography(nil, "GB", "United Kingdom", state: "Scotland")["address_components"] ]) ])
    raw = geography("Edinburgh", "GB", "United Kingdom", state: "Scotland")
      .merge("native_locality" => { "place_id" => "edinburgh-postal", "name" => "Edinburgh" })
    result = resolve(raw, latitude: 55.951, longitude: -3.191)
    assert_equal "google-locality:v1:#{Digest::SHA256.hexdigest('edinburgh-city')}", result[:map_region_key]

    @catalog.observe([ city("chitterne", "Chitterne", "GB", "United Kingdom", "England", 51.2, -2.0),
      city("warminster", "Warminster", "GB", "United Kingdom", "England", 51.2, -2.1) ])
    village = geography("Chitterne", "GB", "United Kingdom", state: "England")
    village["address_components"] << { "long_name" => "Warminster", "types" => [ "postal_town" ] }
    assert_equal "Chitterne", resolve(village, latitude: 51.201, longitude: -2.001)[:map_region_name]

    unknown = geography("Another village", "GB", "United Kingdom", state: "England")
    unknown["address_components"] << { "long_name" => "Warminster", "types" => [ "postal_town" ] }
    assert_match(/\Agoogle-feature:v1:/, resolve(unknown, latitude: 51.201, longitude: -2.001)[:map_region_key])
    unknown.merge!("grouping_version" => LocationGroupingResolver::VERSION, "native_locality" => { "place_id" => "warminster", "name" => "Warminster", "source" => "catalog" })
    assert_match(/\Agoogle-feature:v1:/, resolve(unknown, latitude: 51.201, longitude: -2.001)[:map_region_key])
  end

  test "legacy covers migrate to their current browsing gallery using the newest valid choice" do
    owner = users(:one)
    now = Time.current
    photos = %w[Older Newer].map.with_index do |label, index|
      id = Photo.insert_all!([ { owner_id: owner.id, title: label, created_at: now, updated_at: now } ]).rows.flatten.sole
      place = PhotoPlace.create!(identity_key: "google:#{label}", name: label, names: [ "Previous #{label}" ], place_type: "premise",
        latitude: 43.09, longitude: -79.08, map_region_key: "google-locality:v1:canadian-city", map_region_name: "Niagara Falls")
      PhotoMetadata.create!(photo_id: id, photo_place: place, latitude: 43.09, longitude: -79.08, raw: {})
      owner.photo_location_covers.create!(location_id: PhotoLocation.place_id_for_name("Previous #{label}"), cover_photo_id: id,
        created_at: now + index, updated_at: now + index)
      Photo.find(id)
    end
    owner.photo_location_covers.create!(location_id: PhotoLocation.place_id_for_name("Unrelated place"), cover_photo: photos.first)

    assert_equal 1, LocationGroupingRepair.promote_covers!
    target = PhotoLocationArea.id_for_region("google-locality:v1:canadian-city")
    assert_equal photos.last.id, owner.photo_location_covers.find_by!(location_id: target).cover_photo_id
    assert_equal 4, owner.photo_location_covers.count, "Original legacy choices remain saved"
    assert_equal 0, LocationGroupingRepair.promote_covers!, "Current explicit covers are never overwritten"
  end

  private

  def resolve(raw, latitude:, longitude:, name: "Synthetic landmark")
    LocationGroupingResolver.resolve({ identity_key: "google:precise-feature", name: name, names: [], place_type: "nearby_landmark", raw: raw },
      latitude: latitude, longitude: longitude, catalog: @catalog)
  end

  def geography(locality, country_code, country_name, state: nil)
    components = [ { "long_name" => locality, "types" => [ "locality" ] },
      { "long_name" => state, "short_name" => state, "types" => [ "administrative_area_level_1" ] },
      { "long_name" => country_name, "short_name" => country_code, "types" => [ "country" ] } ].reject { |component| component["long_name"].blank? }
    { "native_name_version" => LocationNativeGeocoder::VERSION, "address_components" => components }
  end

  def city(id, name, country_code, country_name, state, latitude, longitude)
    geography(name, country_code, country_name, state: state).merge("place_id" => id, "types" => [ "locality" ], "geometry" => { "location" => { "lat" => latitude, "lng" => longitude } })
  end
end
