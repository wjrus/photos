require "test_helper"

class LocationReverseGeocoderTest < ActiveSupport::TestCase
  setup do
    @google_maps_embed_api_key = ENV["GOOGLE_MAPS_EMBED_API_KEY"]
    @google_maps_geocoding_api_key = ENV["GOOGLE_MAPS_GEOCODING_API_KEY"]
    @google_geocoding_api_key = ENV["GOOGLE_GEOCODING_API_KEY"]
    @nearby_fallback = ENV["LOCATION_GEOCODER_NEARBY_FALLBACK"]
    @nearby_fallback_daily_limit = ENV["LOCATION_GEOCODER_NEARBY_FALLBACK_DAILY_LIMIT"]
    @nearby_fallback_max_probes = ENV["LOCATION_GEOCODER_NEARBY_FALLBACK_MAX_PROBES"]
    Rails.cache.clear
  end

  teardown do
    ENV["GOOGLE_MAPS_EMBED_API_KEY"] = @google_maps_embed_api_key
    ENV["GOOGLE_MAPS_GEOCODING_API_KEY"] = @google_maps_geocoding_api_key
    ENV["GOOGLE_GEOCODING_API_KEY"] = @google_geocoding_api_key
    ENV["LOCATION_GEOCODER_NEARBY_FALLBACK"] = @nearby_fallback
    ENV["LOCATION_GEOCODER_NEARBY_FALLBACK_DAILY_LIMIT"] = @nearby_fallback_daily_limit
    ENV["LOCATION_GEOCODER_NEARBY_FALLBACK_MAX_PROBES"] = @nearby_fallback_max_probes
    Rails.cache.clear
  end

  test "prefers the server side geocoding key" do
    ENV["GOOGLE_MAPS_EMBED_API_KEY"] = "browser-key"
    ENV["GOOGLE_MAPS_GEOCODING_API_KEY"] = "server-key"

    assert_equal "server-key", LocationReverseGeocoder.api_key
  end

  test "returns nil and logs google status failures" do
    ENV["GOOGLE_MAPS_GEOCODING_API_KEY"] = "server-key"
    response = http_ok_response(
      status: "REQUEST_DENIED",
      error_message: "This API project is not authorized to use this API.",
      results: []
    )

    stub_get_response(response) do
      assert_nil LocationReverseGeocoder.new.geocode(latitude: 44.7622, longitude: -85.5980)
    end
  end

  test "builds a place name from a successful geocode" do
    ENV["GOOGLE_MAPS_GEOCODING_API_KEY"] = "server-key"
    response = http_ok_response(
      status: "OK",
      results: [
        {
          formatted_address: "Traverse City, MI, USA",
          address_components: [
            { long_name: "Traverse City", types: [ "locality", "political" ] },
            { long_name: "Michigan", types: [ "administrative_area_level_1", "political" ] },
            { long_name: "United States", types: [ "country", "political" ] }
          ]
        }
      ]
    )

    stub_get_response(response) do
      result = LocationReverseGeocoder.new.geocode(latitude: 44.7622, longitude: -85.5980)

      assert_equal "Traverse City, Michigan", result[:name]
      assert_equal [ "Traverse City, Michigan", "Traverse City", "Michigan", "United States" ], result[:names]
    end
  end

  test "uses neighborhoods for large cities" do
    ENV["GOOGLE_MAPS_GEOCODING_API_KEY"] = "server-key"
    response = http_ok_response(
      status: "OK",
      results: [
        {
          formatted_address: "Westminster, London, UK",
          address_components: [
            { long_name: "Westminster", types: [ "neighborhood", "political" ] },
            { long_name: "London", types: [ "postal_town" ] },
            { long_name: "England", types: [ "administrative_area_level_1", "political" ] },
            { long_name: "United Kingdom", types: [ "country", "political" ] }
          ]
        }
      ]
    )

    stub_get_response(response) do
      result = LocationReverseGeocoder.new.geocode(latitude: 51.499, longitude: -0.128)

      assert_equal "Westminster, London", result[:name]
      assert_equal [ "Westminster, London", "Westminster", "London", "England", "United Kingdom" ], result[:names]
    end
  end

  test "uses landmark names when locality is too broad" do
    ENV["GOOGLE_MAPS_GEOCODING_API_KEY"] = "server-key"
    response = http_ok_response(
      status: "OK",
      results: [
        {
          formatted_address: "Stonehenge, Salisbury SP4 7DE, UK",
          types: [ "tourist_attraction", "point_of_interest", "establishment" ],
          address_components: [
            { long_name: "Stonehenge", types: [ "tourist_attraction", "point_of_interest", "establishment" ] },
            { long_name: "Salisbury", types: [ "postal_town" ] },
            { long_name: "England", types: [ "administrative_area_level_1", "political" ] },
            { long_name: "United Kingdom", types: [ "country", "political" ] }
          ]
        }
      ]
    )

    stub_get_response(response) do
      result = LocationReverseGeocoder.new.geocode(latitude: 51.1789, longitude: -1.8262)

      assert_equal "Stonehenge, Salisbury", result[:name]
      assert_equal [ "Stonehenge, Salisbury", "Stonehenge", "Salisbury", "England", "United Kingdom" ], result[:names]
    end
  end

  test "skips plus code results in favor of usable places" do
    ENV["GOOGLE_MAPS_GEOCODING_API_KEY"] = "server-key"
    response = http_ok_response(
      status: "OK",
      results: [
        {
          formatted_address: "73H55V7C+Q8",
          types: [ "plus_code" ],
          address_components: [
            { long_name: "73H55V7C+Q8", types: [ "plus_code" ] }
          ]
        },
        {
          formatted_address: "Maui County, HI, USA",
          address_components: [
            { long_name: "Maui County", types: [ "administrative_area_level_2", "political" ] },
            { long_name: "Hawaii", types: [ "administrative_area_level_1", "political" ] },
            { long_name: "United States", types: [ "country", "political" ] }
          ]
        }
      ]
    )

    stub_get_response(response) do
      result = LocationReverseGeocoder.new.geocode(latitude: 21.164478, longitude: -156.12915)

      assert_equal "Maui County, Hawaii", result[:name]
      assert_not_includes result[:names], "73H55V7C+Q8"
    end
  end

  test "does not probe nearby coordinates unless fallback is enabled" do
    ENV["GOOGLE_MAPS_GEOCODING_API_KEY"] = "server-key"
    responses = [
      http_ok_response(
        status: "OK",
        results: [
          {
            formatted_address: "73H55V7C+Q8",
            types: [ "plus_code" ],
            address_components: [
              { long_name: "73H55V7C+Q8", types: [ "plus_code" ] }
            ]
          }
        ]
      ),
      http_ok_response(
        status: "OK",
        results: [
          {
            formatted_address: "Lahaina, HI, USA",
            address_components: [
              { long_name: "Lahaina", types: [ "locality", "political" ] },
              { long_name: "Hawaii", types: [ "administrative_area_level_1", "political" ] },
              { long_name: "United States", types: [ "country", "political" ] }
            ]
          }
        ]
      )
    ]

    calls = stub_get_responses(responses) do
      assert_nil LocationReverseGeocoder.new.geocode(latitude: 21.164478, longitude: -156.12915)
    end

    assert_equal 1, calls
  end

  test "nearby fallback is opt in and budgeted" do
    ENV["GOOGLE_MAPS_GEOCODING_API_KEY"] = "server-key"
    ENV["LOCATION_GEOCODER_NEARBY_FALLBACK"] = "true"
    ENV["LOCATION_GEOCODER_NEARBY_FALLBACK_DAILY_LIMIT"] = "1"
    ENV["LOCATION_GEOCODER_NEARBY_FALLBACK_MAX_PROBES"] = "3"
    responses = [
      http_ok_response(
        status: "OK",
        results: [
          {
            formatted_address: "73H55V7C+Q8",
            types: [ "plus_code" ],
            address_components: [
              { long_name: "73H55V7C+Q8", types: [ "plus_code" ] }
            ]
          }
        ]
      ),
      http_ok_response(
        status: "OK",
        results: [
          {
            formatted_address: "Lahaina, HI, USA",
            address_components: [
              { long_name: "Lahaina", types: [ "locality", "political" ] },
              { long_name: "Hawaii", types: [ "administrative_area_level_1", "political" ] },
              { long_name: "United States", types: [ "country", "political" ] }
            ]
          }
        ]
      )
    ]

    calls = stub_get_responses(responses) do
      result = LocationReverseGeocoder.new.geocode(latitude: 21.164478, longitude: -156.12915)

      assert_equal "Lahaina, Hawaii", result[:name]
    end

    assert_equal 2, calls
  end

  private

  def http_ok_response(payload)
    response = Net::HTTPOK.new("1.1", "200", "OK")
    response.instance_variable_set(:@read, true)
    response.body = payload.to_json
    response
  end

  def stub_get_response(response)
    Net::HTTP.singleton_class.alias_method :original_get_response, :get_response
    Net::HTTP.define_singleton_method(:get_response) { |_uri| response }
    yield
  ensure
    Net::HTTP.singleton_class.alias_method :get_response, :original_get_response
    Net::HTTP.singleton_class.remove_method :original_get_response
  end

  def stub_get_responses(responses)
    calls = 0
    Net::HTTP.singleton_class.alias_method :original_get_response, :get_response
    Net::HTTP.define_singleton_method(:get_response) do |_uri|
      response = responses[[ calls, responses.size - 1 ].min]
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
