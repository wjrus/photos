require "test_helper"

class LocationNativeGeocoderTest < ActiveSupport::TestCase
  test "native requests preserve scripts full provider data and actual bounds without putting the key in URLs or storage" do
    payload = { "results" => [ {
      "placeId" => "krakow-city", "types" => [ "locality", "political" ], "formattedAddress" => "Kraków, Polska",
      "location" => { "latitude" => 50.06, "longitude" => 19.94 },
      "bounds" => { "low" => { "latitude" => 50.0, "longitude" => 19.8 }, "high" => { "latitude" => 50.2, "longitude" => 20.1 } },
      "addressComponents" => [ { "longText" => "Kraków", "shortText" => "Kraków", "types" => [ "locality" ], "languageCode" => "pl" },
        { "longText" => "Polska", "shortText" => "PL", "types" => [ "country" ], "languageCode" => "pl" } ],
      "providerExtraData" => { "preserve" => true }
    } ] }
    with_http([ http_response(payload) ]) do |requests|
      result = LocationNativeGeocoder.new(api_key: "synthetic-server-key").reverse(latitude: 50.06, longitude: 19.94).fetch("results").sole
      assert_equal "Kraków, Polska", result["formatted_address"]
      assert_equal "pl", result["address_components"].first["language_code"]
      assert_equal 50.0, result.dig("geometry", "bounds", "southwest", "lat")
      assert_equal LocationNativeGeocoder::VERSION, result["native_name_version"]
      assert_nil requests.sole.uri.query
      assert_equal "synthetic-server-key", requests.sole["X-Goog-Api-Key"]
      assert_equal "geocode.googleapis.com", requests.sole.uri.host
      assert_equal true, LocationGeocodingResponse.sole.payload.dig("results", 0, "providerExtraData", "preserve")
      refute_includes LocationGeocodingResponse.sole.attributes.to_json, "synthetic-server-key"
    end
  end

  test "responses and valid empty results survive eviction age and missing keys" do
    with_http([ http_response({ "results" => [] }) ]) do |requests|
      assert_equal "ZERO_RESULTS", LocationNativeGeocoder.new(api_key: "key").reverse(latitude: 44, longitude: -80)["status"]
      Rails.cache.clear
      travel 3.years do
        assert_equal "ZERO_RESULTS", LocationNativeGeocoder.new(api_key: nil).reverse(latitude: 44, longitude: -80)["status"]
      end
      assert_equal 1, requests.size
    end
  end

  test "only uncached network attempts consume the persistent repair allowance" do
    with_http([ http_response({ "results" => [] }) ]) do |requests|
      client = LocationNativeGeocoder.new(api_key: "key")
      LocationApiBudget.with_repair_limit(cents: 1) do
        2.times { client.reverse(latitude: 44, longitude: -80) }
      end
      assert_equal 1, requests.size
      assert_equal 5_000, LocationApiBudget.status.fetch("reserved")
      assert_equal({ "geocoding" => 1 }, LocationApiBudget.status.fetch("requests"))
    end
  end

  test "a missing key stops uncached repair lookups rather than marking their names unavailable" do
    assert_raises(LocationNativeGeocoder::LookupError) do
      LocationNativeGeocoder.new(api_key: nil).reverse(latitude: 44, longitude: -80)
    end
    assert_equal 0, LocationGeocodingResponse.count
    assert_equal 0, LocationApiBudget.status.fetch("reserved")
  end

  test "permission and malformed response failures remain retryable" do
    with_http([ http_response({}, status: "403"), http_response({ "results" => "invalid" }), http_response({ "results" => [] }) ]) do |requests|
      client = LocationNativeGeocoder.new(api_key: "key")
      error = assert_raises(LocationNativeGeocoder::LookupError) { client.reverse(latitude: 44, longitude: -80) }
      assert_equal 403, error.http_status
      assert_raises(LocationNativeGeocoder::LookupError) { client.reverse(latitude: 44, longitude: -80) }
      assert_equal 0, LocationGeocodingResponse.count
      assert_equal "ZERO_RESULTS", client.reverse(latitude: 44, longitude: -80)["status"]
      assert_equal 3, requests.size
    end
  end

  test "place and address paths encode user input and retain native text" do
    with_http([ http_response({ "placeId" => "site/id", "types" => [ "natural_feature" ], "formattedAddress" => "Kerlingarfjöll" }), http_response({ "results" => [] }) ]) do |requests|
      client = LocationNativeGeocoder.new(api_key: "key")
      assert_equal "Kerlingarfjöll", client.place(place_id: "site/id")["formatted_address"]
      client.address(address: "Kerlingarfjöll, Ísland")
      assert_includes requests.first.path, "site%2Fid"
      assert_includes requests.last.path, "Kerlingarfj%C3%B6ll"
      assert requests.all? { |request| !request.path.include?("languageCode") }
    end
  end

  private

  def http_response(payload, status: "200")
    response = status == "200" ? Net::HTTPOK.new("1.1", status, "OK") : Net::HTTPForbidden.new("1.1", status, "Forbidden")
    response.instance_variable_set(:@read, true)
    response.body = payload.to_json
    response
  end

  def with_http(responses)
    original = Net::HTTP.method(:start)
    requests = []
    http = Object.new
    http.define_singleton_method(:request) do |request|
      requests << request
      responses.fetch(requests.size - 1)
    end
    Net::HTTP.define_singleton_method(:start) { |*_args, **_options, &block| block.call(http) }
    yield requests
  ensure
    Net::HTTP.define_singleton_method(:start, original)
  end
end
