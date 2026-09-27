require "test_helper"

class LocationAddressGeocoderTest < ActiveSupport::TestCase
  setup do
    @previous_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    @google_maps_embed_api_key = ENV["GOOGLE_MAPS_EMBED_API_KEY"]
    @google_maps_geocoding_api_key = ENV["GOOGLE_MAPS_GEOCODING_API_KEY"]
    @google_geocoding_api_key = ENV["GOOGLE_GEOCODING_API_KEY"]
    Rails.cache.clear
  end

  teardown do
    Rails.cache = @previous_cache
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
          place_id: "city-id",
          types: [ "locality", "political" ],
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
      assert_equal "google:city-id", result[:identity_key]
      assert_equal "city-id", result[:provider_place_id]
      assert_equal "google", result[:provider]
      assert_equal "locality", result[:place_type]
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

  test "explicit address results keep their own address identity instead of a locality label" do
    response = http_ok_response(status: "OK", results: [
      {
        place_id: "street-id", types: [ "street_address" ], formatted_address: "123 Main St, Example Town",
        geometry: { location: { lat: 44.7622004, lng: -85.5980004 } },
        address_components: [ { long_name: "Example Town", types: [ "locality" ] } ]
      }
    ])

    stub_get_response(response) do
      result = LocationAddressGeocoder.new(api_key: "server-key").geocode(address: "123 Main St, Example Town")
      assert_equal "google:street-id", result[:identity_key]
      assert_equal "street_address", result[:place_type]
      assert_equal "123 Main St, Example Town", result[:name]
      assert_equal BigDecimal("44.762200"), result[:latitude]
      assert_equal BigDecimal("-85.598000"), result[:longitude]
      assert_includes result[:names], "Example Town"
    end
  end

  test "address without a provider ID uses exact coordinates as identity" do
    response = http_ok_response(status: "OK", results: [
      { formatted_address: "Example Town", geometry: { location: { lat: 44.7622, lng: -85.598 } } }
    ])

    stub_get_response(response) do
      result = LocationAddressGeocoder.new(api_key: "server-key").geocode(address: "Example Town")
      assert_equal "coordinate:44.762200,-85.598000", result[:identity_key]
      assert_equal "44.762200, -85.598000", result[:name]
      assert_includes result[:names], "Example Town"
      assert_nil result[:provider_place_id]
      assert_equal "coordinate", result[:place_type]
    end
  end

  test "Plus Code address results keep coordinate identity even with a provider ID" do
    response = http_ok_response(status: "OK", results: [
      {
        place_id: "plus-code-id", formatted_address: "73H55V7C+Q8",
        geometry: { location: { lat: 21.164478, lng: -156.12915 } }
      }
    ])

    stub_get_response(response) do
      result = LocationAddressGeocoder.new(api_key: "server-key").geocode(address: "73H55V7C+Q8")
      assert_equal "coordinate:21.164478,-156.129150", result[:identity_key]
      assert_equal "73H55V7C+Q8", result[:name]
      assert_nil result[:provider_place_id]
    end
  end

  test "manual addresses use the same London region hierarchy without merging venue identity" do
    response = http_ok_response(status: "OK", results: [
      {
        place_id: "greenwich-venue", types: [ "premise" ], formatted_address: "Explicit Greenwich venue",
        geometry: { location: { lat: 51.4, lng: 0 } },
        address_components: [
          { long_name: "Greenwich", types: [ "locality" ] },
          { long_name: "Greater London", types: [ "administrative_area_level_2" ] },
          { long_name: "England", types: [ "administrative_area_level_1" ] },
          { long_name: "United Kingdom", types: [ "country" ] }
        ]
      }
    ])

    stub_get_response(response) do
      result = LocationAddressGeocoder.new(api_key: "server-key").geocode(address: "Explicit Greenwich venue")
      assert_equal "google:greenwich-venue", result[:identity_key]
      assert_equal "Explicit Greenwich venue", result[:name]
      assert_equal "London", result[:map_region_name]
      assert_equal 'google-components:v1:["metro","gb","england","greater london"]', result[:map_region_key]
      assert_includes result[:names], "London"
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
