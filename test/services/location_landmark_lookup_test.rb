require "test_helper"

class LocationLandmarkLookupTest < ActiveSupport::TestCase
  setup do
    @cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    @lookup = LocationLandmarkLookup.new(api_key: "synthetic-places-key")
  end

  teardown do
    Rails.cache = @cache
  end

  test "looks up named attractions and preserves their town components without returning replacement GPS" do
    attraction = place("gullfoss", "Gullfoss", 64.3274, -20.1200)
    attraction[:addressComponents] = [ { longText: "Iceland", shortText: "IS", types: [ "country" ] } ]
    with_responses([ response(places: [ attraction, place("far", "Far waterfall", 64.4, -20.1) ]) ]) do |requests|
      result = @lookup.geocode(latitude: 64.3279, longitude: -20.1195)
      assert_equal "Gullfoss", result[:name]
      assert_equal "google:gullfoss", result[:identity_key]
      assert_equal "nearby_landmark", result[:place_type]
      assert_includes result[:names], "Iceland"
      assert_equal "Iceland", result[:raw].fetch("address_components").first.fetch("long_name")
      refute result.key?(:latitude)
      refute result.key?(:longitude)
      refute_includes result[:raw].to_s, "synthetic-places-key"

      request = requests.sole
      assert_equal "synthetic-places-key", request["X-Goog-Api-Key"]
      assert_includes request["X-Goog-FieldMask"], "places.addressComponents"
      refute_includes request["X-Goog-FieldMask"], "reviews"
      body = JSON.parse(request.body)
      assert_equal 10, body.fetch("maxResultCount")
      assert_equal 600, body.dig("locationRestriction", "circle", "radius")
      assert_equal 64.328, body.dig("locationRestriction", "circle", "center", "latitude")
    end
  end

  test "cached nearby results are checked against each photos actual point" do
    with_responses([ response(places: [ place("edge", "Edge viewpoint", 64.3323, -20.1195) ]) ]) do |requests|
      assert_equal "Edge viewpoint", @lookup.geocode(latitude: 64.3279, longitude: -20.1195)[:name]
      assert_nil @lookup.geocode(latitude: 64.32751, longitude: -20.11951)
      assert_equal 1, requests.size
    end
  end

  test "ordinary businesses malformed places and distant attractions do not provide a landmark name" do
    candidates = [
      place("business", "Restaurant", 64.3279, -20.1195).merge(types: [ "restaurant" ]),
      place("far", "Far viewpoint", 64.4, -20.1),
      { id: "bad", displayName: "not a name object", types: [ "tourist_attraction" ] }
    ]
    with_responses([ response(places: candidates) ]) do
      assert_nil @lookup.geocode(latitude: 64.3279, longitude: -20.1195)
    end
  end

  test "API denials are visible errors and are not cached as successful empty results" do
    denied = Net::HTTPForbidden.new("1.1", "403", "Forbidden")
    with_responses([ denied, response(places: [ place("gullfoss", "Gullfoss", 64.3274, -20.1200) ]) ]) do |requests|
      error = assert_raises(LocationLandmarkLookup::LookupError) { @lookup.geocode(latitude: 64.3279, longitude: -20.1195) }
      assert_includes error.message, "403"
      refute_includes error.message, "synthetic-places-key"
      assert_equal "Gullfoss", @lookup.geocode(latitude: 64.3279, longitude: -20.1195)[:name]
      assert_equal 2, requests.size
    end
  end

  test "valid empty results are cached and missing configuration is reported" do
    with_responses([ response(places: []) ]) do |requests|
      2.times { assert_nil @lookup.geocode(latitude: 64.3279, longitude: -20.1195) }
      assert_equal 1, requests.size
    end
    assert_raises(LocationLandmarkLookup::LookupError) do
      LocationLandmarkLookup.new(api_key: nil).geocode(latitude: 65, longitude: -20)
    end
  end

  test "database responses have no expiry and are reusable without an API key" do
    with_responses([ response(places: [ place("gullfoss", "Gullfoss", 64.3274, -20.1200) ]) ]) do |requests|
      assert_equal "Gullfoss", @lookup.geocode(latitude: 64.3279, longitude: -20.1195)[:name]
      Rails.cache.clear
      travel 2.years do
        assert_equal "Gullfoss", LocationLandmarkLookup.new(api_key: nil).geocode(latitude: 64.3279, longitude: -20.1195)[:name]
      end
      assert_equal 1, requests.size
      refute_includes LocationGeocodingResponse.first.payload.to_json, "synthetic-places-key"
    end
  end

  test "malformed API payloads are not cached" do
    with_responses([ response(places: "invalid"), response(places: []) ]) do |requests|
      assert_raises(LocationLandmarkLookup::LookupError) { @lookup.geocode(latitude: 64.3279, longitude: -20.1195) }
      assert_nil @lookup.geocode(latitude: 64.3279, longitude: -20.1195)
      assert_equal 2, requests.size
    end
  end

  test "native campground searches include Kerlingarfjoll and reject a nearby feature in another country" do
    campsite = place("asgardur", "Ásgarður (Kerlingarfjöll)", 64.6832, -19.30).merge(types: [ "campground", "lodging" ], addressComponents: [ { longText: "Ísland", shortText: "IS", types: [ "country" ] } ])
    foreign = place("other-country", "Foreign feature", 64.6832, -19.30).merge(addressComponents: [ { longText: "Other country", shortText: "XX", types: [ "country" ] } ])
    with_responses([ response(places: [ foreign, campsite ]) ]) do |requests|
      result = @lookup.geocode(latitude: 64.6832, longitude: -19.30, language_code: "is", country_code: "IS")
      assert_equal "Ásgarður (Kerlingarfjöll)", result[:name]
      assert_equal LocationNativeGeocoder::VERSION, result[:raw]["native_name_version"]
      assert_equal "is", JSON.parse(requests.sole.body)["languageCode"]
      assert_includes JSON.parse(requests.sole.body)["includedTypes"], "campground"
    end
  end

  private

  def place(id, name, latitude, longitude)
    { id: id, displayName: { text: name }, types: [ "tourist_attraction" ], location: { latitude: latitude, longitude: longitude } }
  end

  def response(payload)
    response = Net::HTTPOK.new("1.1", "200", "OK")
    response.instance_variable_set(:@read, true)
    response.body = payload.to_json
    response
  end

  def with_responses(responses)
    original = Net::HTTP.method(:start)
    requests = []
    client = Object.new
    client.define_singleton_method(:request) do |request|
      requests << request
      responses.fetch(requests.size - 1)
    end
    Net::HTTP.define_singleton_method(:start) { |*_args, **_options, &block| block.call(client) }
    yield requests
  ensure
    Net::HTTP.define_singleton_method(:start, original)
  end
end
