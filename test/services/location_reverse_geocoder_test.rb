require "test_helper"

class LocationReverseGeocoderTest < ActiveSupport::TestCase
  setup do
    @google_maps_embed_api_key = ENV["GOOGLE_MAPS_EMBED_API_KEY"]
    @google_maps_geocoding_api_key = ENV["GOOGLE_MAPS_GEOCODING_API_KEY"]
    @google_geocoding_api_key = ENV["GOOGLE_GEOCODING_API_KEY"]
    Rails.cache.clear
  end

  teardown do
    ENV["GOOGLE_MAPS_EMBED_API_KEY"] = @google_maps_embed_api_key
    ENV["GOOGLE_MAPS_GEOCODING_API_KEY"] = @google_maps_geocoding_api_key
    ENV["GOOGLE_GEOCODING_API_KEY"] = @google_geocoding_api_key
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
end
