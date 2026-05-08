require "test_helper"

class LocationAddressGeocoderTest < ActiveSupport::TestCase
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

  test "returns nil without an api key" do
    ENV["GOOGLE_MAPS_EMBED_API_KEY"] = nil
    ENV["GOOGLE_MAPS_GEOCODING_API_KEY"] = nil
    ENV["GOOGLE_GEOCODING_API_KEY"] = nil

    assert_nil LocationAddressGeocoder.new.geocode(address: "Traverse City, MI")
  end

  test "builds coordinates and names from a successful address geocode" do
    ENV["GOOGLE_MAPS_GEOCODING_API_KEY"] = "server-key"
    response = http_ok_response(
      status: "OK",
      results: [
        {
          formatted_address: "Traverse City, MI, USA",
          geometry: { location: { lat: 44.7608, lng: -85.6228 } },
          address_components: [
            { long_name: "Traverse City", types: [ "locality", "political" ] },
            { long_name: "Grand Traverse County", types: [ "administrative_area_level_2", "political" ] },
            { long_name: "Michigan", types: [ "administrative_area_level_1", "political" ] },
            { long_name: "United States", types: [ "country", "political" ] }
          ]
        }
      ]
    )

    stub_get_response(response) do
      result = LocationAddressGeocoder.new.geocode(address: "Traverse City, MI")

      assert_equal BigDecimal("44.7608"), result[:latitude]
      assert_equal BigDecimal("-85.6228"), result[:longitude]
      assert_equal "Traverse City, MI, USA", result[:name]
      assert_equal [ "Traverse City, MI, USA", "Traverse City, MI", "Traverse City", "Grand Traverse County", "Michigan", "United States" ], result[:names]
    end
  end

  test "returns nil and logs google status failures" do
    ENV["GOOGLE_MAPS_GEOCODING_API_KEY"] = "server-key"
    response = http_ok_response(status: "ZERO_RESULTS", results: [])

    stub_get_response(response) do
      assert_nil LocationAddressGeocoder.new.geocode(address: "Not a real place")
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
