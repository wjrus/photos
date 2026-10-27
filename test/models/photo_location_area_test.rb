require "test_helper"

class PhotoLocationAreaTest < ActiveSupport::TestCase
  setup do
    @photos = []
    @blob = ActiveStorage::Blob.create_and_upload!(io: File.open(Rails.root.join("public/icon.png")), filename: "area.png", content_type: "image/png")
  end

  test "nearby Grand Canyon Plus Codes form one readable area without changing precise assignments" do
    make_photo(36.0479, -112.0942, "2WX4+58 Grand Canyon Village")
    make_photo(36.0479, -112.0941, "2WX4+59 Grand Canyon Village")
    make_photo(36.0480, -112.0944, "2WX4+66 Grand Canyon Village")
    before = PhotoMetadata.where(photo_id: @photos).order(:photo_id).pluck(:photo_place_id, :latitude, :longitude)

    area = PhotoLocationArea.groups(scope).sole

    assert_equal "Grand Canyon Village", area.title
    assert_equal "nearby_area", area.place_type
    assert_equal 3, area.photo_count
    assert_equal 1, PhotoLocationArea.group_count(scope)
    assert_equal @photos.map(&:id).sort, PhotoLocation.scope_for(scope, area.id).pluck(:id).sort
    assert_equal 3, PhotoLocation.groups(scope).size
    assert_equal before, PhotoMetadata.where(photo_id: @photos).order(:photo_id).pluck(:photo_place_id, :latitude, :longitude)
  end

  test "bare codes use a nearby area rather than a misleading or duplicated code title" do
    make_photo(44.0924, -87.6508, "38RX+HF")
    make_photo(44.0923, -87.6508, "38RX+HF")

    area = PhotoLocationArea.groups(scope).sole
    assert_equal 2, area.photo_count
    assert_match(/Nearby/, area.title)
    refute_includes area.title, "38RX"
  end

  test "saved town components group venues across coordinate cells and keep nearby towns separate" do
    first = make_photo(44.09, -87.65, "Harbor", type: "premise", raw: town("Manitowoc"))
    second = make_photo(44.15, -87.70, "Museum", type: "premise", raw: town("Manitowoc"))
    other = make_photo(44.15, -87.60, "Beach", type: "premise", raw: town("Two Rivers"))

    groups = PhotoLocationArea.groups(scope, sort: "name")
    assert_equal [ "Manitowoc", "Two Rivers" ], groups.map(&:title)
    assert_equal [ 2, 1 ], groups.map(&:photo_count)
    assert_equal [ first.id, second.id ].sort, PhotoLocation.scope_for(scope, groups.first.id).pluck(:id).sort
    assert_equal [ other.id ], PhotoLocation.scope_for(scope, groups.last.id).pluck(:id)
    assert_equal 3, PhotoLocation.groups(scope).size
  end

  test "existing London map hierarchy is also a browsing area" do
    key = 'google-components:v1:["metro","gb","england","greater london"]'
    make_photo(51.50, -0.12, "Westminster", type: "neighborhood", region_key: key, region_name: "London")
    make_photo(51.48, 0.01, "Greenwich", type: "neighborhood", region_key: key, region_name: "London")

    area = PhotoLocationArea.groups(scope).sole
    assert_equal PhotoLocationArea.id_for_region(key), area.id
    assert_equal "London", area.title
    assert_equal 2, area.photo_count
  end

  test "saved components and already resolved map regions produce identical town identifiers" do
    raw = town('Town with "quotes"', county: 'West, "North" County')
    region = LocationMapRegion.for_result(raw)
    make_photo(44.09, -87.65, "Old venue", type: "premise", raw: raw)
    make_photo(44.15, -87.70, "New venue", type: "premise", raw: raw,
      region_key: region.fetch(:map_region_key), region_name: region.fetch(:map_region_name))

    area = PhotoLocationArea.groups(scope).sole
    assert_equal 2, area.photo_count
    assert_equal PhotoLocationArea.id_for_region(region.fetch(:map_region_key)), area.id
  end

  test "namesakes in different counties and distant hints never share an area" do
    make_photo(40, -80, "Venue", type: "premise", raw: town("Springfield", county: "One"))
    make_photo(41, -81, "Venue", type: "premise", raw: town("Springfield", county: "Two"))
    make_photo(42, -82, "2WX4+58 Springfield")
    make_photo(43, -83, "2WX4+59 Springfield")

    assert_equal 4, PhotoLocationArea.groups(scope).size
    assert_equal 4, PhotoLocationArea.group_count(scope)
  end

  test "mixed unqualified hints do not borrow one towns name for all photos" do
    make_photo(40.01, -80.01, "2WX4+58 One Town")
    make_photo(40.02, -80.02, "2WX4+59 Other Town")

    area = PhotoLocationArea.groups(scope).sole
    assert_match(/Nearby/, area.title)
    refute_includes area.title, "Town"
  end

  test "area membership respects the supplied visibility and ordering" do
    visible = make_photo(44.09, -87.65, "38RX+HF")
    hidden = make_photo(44.091, -87.651, "38RX+HG")
    visible.publish!
    hidden.update!(archived_at: Time.current)
    visible_scope = scope.merge(Photo.visible_to(users(:two)))

    area = PhotoLocationArea.groups(visible_scope).sole
    assert_equal 1, area.photo_count
    assert_equal [ visible.id ], PhotoLocation.scope_for(visible_scope.order(id: :desc), area.id).pluck(:id)
    assert_includes PhotoLocation.scope_for(visible_scope.order(id: :desc), area.id).to_sql, '"photos"."id" DESC'
    assert_empty PhotoLocationArea.scope_for(scope, "region-invalid")
    refute PhotoLocation.valid_id?("nearby-9999_9999")
  end

  test "geography sorts country then US state then city while omitting international state levels" do
    make_photo(41.5, -81.7, "Cleveland Ohio", type: "premise", raw: town("Cleveland", state: "Ohio"))
    make_photo(42.7, -84.5, "Cleveland Michigan", type: "premise", raw: town("Cleveland", state: "Michigan"))
    make_photo(42.3, -83.1, "Detroit", type: "premise", raw: town("Detroit", state: "Michigan"))
    make_photo(33.4, -112.1, "Phoenix", type: "premise", raw: town("Phoenix", state: "Arizona"))
    make_photo(64.3, -20.1, "Gullfoss", type: "nearby_landmark", raw: town(nil, state: "Southern Region", country: "Iceland"))
    make_photo(51.5, -0.1, "London", type: "premise", raw: town("London", state: "England", country: "United Kingdom", county: "Greater London"))
    make_photo(0, 0, "Unmatched")
    before = scope.pluck("photos.id", "photo_metadata.photo_place_id", "photo_metadata.latitude", "photo_metadata.longitude")

    areas = PhotoLocationArea.groups(scope, sort: "geography")
    assert_equal [ "Gullfoss", "London", "Phoenix", "Cleveland", "Detroit", "Cleveland" ], areas.first(6).map(&:title)
    assert_equal [ "Iceland", "United Kingdom", "United States", "United States", "United States", "United States", nil ], areas.map(&:country_name)
    assert_equal [ nil, nil, "Arizona", "Michigan", "Michigan", "Ohio", nil ], areas.map(&:state_name)
    assert_equal "United States · Ohio", areas[-2].geographic_context
    assert_equal "Iceland", areas.first.geographic_context
    assert_equal areas.drop(2).take(2).map(&:id), PhotoLocationArea.groups(scope, sort: "geography", limit: 2, offset: 2).map(&:id)
    assert_equal areas.map(&:id), PhotoLocationArea.groups(scope, sort: "name").map(&:id)
    assert_equal before, scope.pluck("photos.id", "photo_metadata.photo_place_id", "photo_metadata.latitude", "photo_metadata.longitude")
  end

  test "conflicting or missing country context never borrows a state from one photo" do
    make_photo(40.01, -80.01, "2WX4+58 Border", raw: town(nil, state: "Ohio"))
    make_photo(40.02, -80.02, "2WX4+59 Border", raw: town(nil, country: "Canada", state: "Ontario"))
    make_photo(43, -83, "Unknown", raw: { address_components: [ { long_name: "Ohio", types: [ "administrative_area_level_1" ] } ] })

    areas = PhotoLocationArea.groups(scope, sort: "geography")
    assert_equal 2, areas.size
    assert areas.all? { |area| area.country_name.nil? && area.state_name.nil? }
  end

  private

  def scope
    Photo.where(id: @photos.map(&:id)).joins(:metadata)
  end

  def make_photo(latitude, longitude, name, type: "coordinate", raw: {}, region_key: nil, region_name: nil)
    photo = users(:one).photos.create!(title: name, original: @blob)
    metadata = photo.create_metadata!(latitude: latitude, longitude: longitude, extraction_status: "complete", raw: {})
    place = PhotoPlace.create!(identity_key: "test:#{SecureRandom.uuid}", name: name, place_type: type, raw: raw,
      latitude: latitude, longitude: longitude, map_region_key: region_key, map_region_name: region_name)
    metadata.update!(photo_place: place, location_source: "automatic")
    @photos << photo
    photo
  end

  def town(name, county: "Manitowoc County", state: "Wisconsin", country: "United States")
    { address_components: [
      { long_name: name, types: [ "locality" ] },
      { long_name: county, types: [ "administrative_area_level_2" ] },
      { long_name: state, types: [ "administrative_area_level_1" ] },
      { long_name: country, types: [ "country" ] }
    ] }
  end
end
