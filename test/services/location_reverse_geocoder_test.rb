require "test_helper"

class LocationReverseGeocoderTest < ActiveSupport::TestCase
  setup do
    @previous_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    @previous_env = %w[GOOGLE_MAPS_EMBED_API_KEY GOOGLE_MAPS_GEOCODING_API_KEY GOOGLE_GEOCODING_API_KEY LOCATION_GEOCODER_NEARBY_FALLBACK].index_with { |key| ENV[key] }
    ENV["GOOGLE_MAPS_GEOCODING_API_KEY"] = "server-key"
  end

  teardown do
    Rails.cache = @previous_cache
    @previous_env.each { |key, value| ENV[key] = value }
  end

  test "prefers the server side geocoding key" do
    ENV["GOOGLE_MAPS_EMBED_API_KEY"] = "browser-key"
    assert_equal "server-key", LocationReverseGeocoder.api_key
  end

  test "uses the actual locality result identity instead of the first street address identity" do
    street = geography_result("street-id", "street_address", "123 Main Street")
    locality = geography_result("city-id", "locality", "Traverse City")

    result = geocode_results([ street, locality ])

    assert_equal "google:city-id", result[:identity_key]
    assert_equal "google", result[:provider]
    assert_equal "city-id", result[:provider_place_id]
    assert_equal "locality", result[:place_type]
    assert_equal "Traverse City, Michigan", result[:name]
    assert_equal "city-id", result[:raw].fetch("place_id")
    assert_includes result[:names], "Grand Traverse County"
  end

  test "uses coordinate identity when locality exists only as a street address component" do
    result = geocode_results([ geography_result("street-id", "street_address", "123 Main Street") ])

    assert_equal "coordinate:44.762200,-85.598000", result[:identity_key]
    assert_equal "44.762200, -85.598000", result[:name]
    assert_nil result[:provider_place_id]
    assert_nil result[:provider]
    assert_equal "coordinate", result[:place_type]
    assert_includes result[:names], "Traverse City"
  end

  test "prefers a named neighborhood in any city and keeps its own identity" do
    results = [
      geography_result("county-id", "administrative_area_level_2", "Grand Traverse County"),
      geography_result("city-id", "locality", "Traverse City"),
      geography_result("neighborhood-id", "neighborhood", "Old Town")
    ]

    result = geocode_results(results)

    assert_equal "google:neighborhood-id", result[:identity_key]
    assert_equal "Old Town, Traverse City", result[:name]
    assert_includes result[:names], "Old Town"
    assert_includes result[:names], "Michigan"
  end

  test "prefers a locality over broad administrative results" do
    result = geocode_results([
      geography_result("county-id", "administrative_area_level_2", "Grand Traverse County"),
      geography_result("city-id", "locality", "Traverse City")
    ])

    assert_equal "google:city-id", result[:identity_key]
  end

  test "broad county names stay aliases rather than collapsing all unresolved photos" do
    result = geocode_results([ geography_result("county-id", "administrative_area_level_2", "Grand Traverse County") ])

    assert_equal "coordinate:44.762200,-85.598000", result[:identity_key]
    assert_equal "44.762200, -85.598000", result[:name]
    assert_includes result[:names], "Grand Traverse County"
  end

  test "specificity and identity resolve ties independently of response order" do
    first = geography_result("a-neighborhood", "neighborhood", "Old Town")
    second = geography_result("b-neighborhood", "neighborhood", "Old Town")
    city = geography_result("city-id", "locality", "Traverse City")
    one = geocode_results([ second, city, first ])
    Rails.cache.clear
    two = geocode_results([ first, second, city ])

    assert_equal "google:a-neighborhood", one[:identity_key]
    assert_equal one[:identity_key], two[:identity_key]
  end

  test "identical display names with different provider identities remain distinct" do
    one = geocode_results([ geography_result("town-one", "locality", "Springfield") ])
    two = geocode_results([ geography_result("town-two", "locality", "Springfield") ], latitude: 43.7622)

    assert_equal one[:name], two[:name]
    refute_equal one[:identity_key], two[:identity_key]
  end

  test "uses an actual named point of interest only at the exact stored coordinate" do
    landmark = geography_result("landmark-id", "point_of_interest", "Historic Lighthouse")
      .merge(geometry: { location: { lat: 44.7622004, lng: -85.5980004 } })
    city = geography_result("city-id", "locality", "Traverse City")

    result = geocode_results([ city, landmark ])

    assert_equal "google:landmark-id", result[:identity_key]
    assert_equal "Historic Lighthouse, Traverse City", result[:name]
    assert_equal "point_of_interest", result[:place_type]
  end

  test "does not infer a visit to a nearby point of interest" do
    landmark = geography_result("nearby-landmark-id", "point_of_interest", "Historic Lighthouse")
      .merge(geometry: { location: { lat: 44.7623, lng: -85.5980 } })

    result = geocode_results([ landmark, geography_result("city-id", "locality", "Traverse City") ])

    assert_equal "google:city-id", result[:identity_key]
    refute_includes result[:names], "Historic Lighthouse"
  end

  test "a missing feature ID or partial match cannot become a shared place identity" do
    result = geocode_results([
      geography_result(nil, "neighborhood", "Old Town"),
      geography_result("partial-city-id", "locality", "Traverse City").merge(partial_match: true)
    ])

    assert_equal "coordinate:44.762200,-85.598000", result[:identity_key]
    assert_includes result[:names], "Old Town"
  end

  test "Plus Codes retain coordinate identity and never trigger nearby probes" do
    ENV["LOCATION_GEOCODER_NEARBY_FALLBACK"] = "true"
    plus_code = { place_id: "plus-code-id", formatted_address: "73H55V7C+Q8", types: [ "plus_code" ] }
    calls = stub_get_responses([ http_ok_response(status: "OK", results: [ plus_code ]) ]) do
      result = LocationReverseGeocoder.new.geocode(latitude: 21.164478, longitude: -156.12915)
      assert_equal "73H55V7C+Q8", result[:name]
      assert_equal "coordinate:21.164478,-156.129150", result[:identity_key]
      assert_nil result[:provider_place_id]
    end

    assert_equal 1, calls
  end

  test "zero results use exact coordinate identity without pretending the county is resolved" do
    response = http_ok_response(status: "ZERO_RESULTS", results: [])
    stub_get_responses([ response ]) do
      result = LocationReverseGeocoder.new.geocode(latitude: 44.7622, longitude: -85.598)
      assert_equal "coordinate:44.762200,-85.598000", result[:identity_key]
      assert_equal "44.762200, -85.598000", result[:name]
    end
  end

  test "returns nil for permission failures so failed requests can be retried" do
    response = http_ok_response(status: "REQUEST_DENIED", results: [])
    stub_get_responses([ response ]) do
      assert_nil LocationReverseGeocoder.new.geocode(latitude: 44.7622, longitude: -85.598)
    end
  end

  test "cache uses six decimal coordinates and does not reuse legacy label-only entries" do
    Rails.cache.write("location-reverse-geocoder/v3/44.76220,-85.59800", { name: "Wrong old place" })
    responses = [
      http_ok_response(status: "OK", results: [ geography_result("first-id", "locality", "First town") ]),
      http_ok_response(status: "OK", results: [ geography_result("second-id", "locality", "Second town") ])
    ]
    calls = stub_get_responses(responses) do
      first = LocationReverseGeocoder.new.geocode(latitude: 44.762201, longitude: -85.598)
      second = LocationReverseGeocoder.new.geocode(latitude: 44.762202, longitude: -85.598)
      cached = LocationReverseGeocoder.new.geocode(latitude: 44.762201, longitude: -85.598)
      assert_equal "google:first-id", first[:identity_key]
      assert_equal "google:second-id", second[:identity_key]
      assert_equal first, cached
    end

    assert_equal 2, calls
  end

  test "coordinate identity normalizes signed zero and precision" do
    result = LocationReverseGeocoder.coordinate_identity(latitude: "-0.0000001", longitude: "-85.5980004")
    assert_equal "coordinate:0.000000,-85.598000", result[:identity_key]
  end

  test "reverse geocoding adds London map rollup while preserving borough identity" do
    result = geocode_results([
      {
        place_id: "westminster-feature", types: [ "neighborhood" ],
        address_components: [
          { long_name: "Westminster", types: [ "neighborhood" ] },
          { long_name: "Westminster", types: [ "postal_town" ] },
          { long_name: "Greater London", types: [ "administrative_area_level_2" ] },
          { long_name: "England", types: [ "administrative_area_level_1" ] },
          { long_name: "United Kingdom", short_name: "GB", types: [ "country" ] }
        ]
      }
    ])

    assert_equal "google:westminster-feature", result[:identity_key]
    assert_equal "neighborhood", result[:place_type]
    assert_equal "London", result[:map_region_name]
    assert_equal 'google-components:v1:["metro","gb","england","greater london"]', result[:map_region_key]
    assert_includes result[:names], "London"
  end

  private

  def geocode_results(results, latitude: 44.7622, longitude: -85.5980)
    result = nil
    stub_get_responses([ http_ok_response(status: "OK", results: results) ]) do
      result = LocationReverseGeocoder.new.geocode(latitude: latitude, longitude: longitude)
    end
    result
  end

  def geography_result(id, type, name)
    {
      place_id: id,
      types: [ type ],
      formatted_address: "#{name}, MI, USA",
      address_components: [
        { long_name: name, types: [ type ] },
        { long_name: "Traverse City", types: [ "locality", "political" ] },
        { long_name: "Grand Traverse County", types: [ "administrative_area_level_2", "political" ] },
        { long_name: "Michigan", types: [ "administrative_area_level_1", "political" ] },
        { long_name: "United States", types: [ "country", "political" ] }
      ]
    }
  end

  def http_ok_response(payload)
    response = Net::HTTPOK.new("1.1", "200", "OK")
    response.instance_variable_set(:@read, true)
    response.body = payload.to_json
    response
  end

  def stub_get_responses(responses)
    calls = 0
    Net::HTTP.singleton_class.alias_method :original_get_response, :get_response
    Net::HTTP.define_singleton_method(:get_response) do |_uri|
      response = responses.fetch(calls)
      calls += 1
      response
    end
    yield
    calls
  ensure
    Net::HTTP.singleton_class.alias_method :get_response, :original_get_response
    Net::HTTP.singleton_class.remove_method :original_get_response
  end
end
