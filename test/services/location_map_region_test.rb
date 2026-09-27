require "test_helper"

class LocationMapRegionTest < ActiveSupport::TestCase
  test "Greater London boroughs roll up as London without changing their place identities" do
    westminster = result(locality: "Westminster", county: "Greater London", region: "England", country: "United Kingdom", country_code: "GB")
    greenwich = result(locality: "Greenwich", county: "Greater London", region: "England", country: "United Kingdom")
    one = LocationMapRegion.for_result(westminster)
    two = LocationMapRegion.for_result(greenwich)

    assert_equal "London", one[:map_region_name]
    assert_equal one, two
    assert_equal 'google-components:v1:["metro","gb","england","greater london"]', one[:map_region_key]
    refute one.key?(:identity_key)
  end

  test "London override does not require or depend on a borough postal town" do
    raw = result(locality: nil, county: "Greater London", region: "England", country: "United Kingdom", country_code: "GB")
    raw[:address_components] << { long_name: "Richmond", types: [ "postal_town" ] }

    assert_equal "London", LocationMapRegion.for_result(raw)[:map_region_name]
  end

  test "locality rollups require a fully qualified hierarchy" do
    raw = result(locality: "Traverse City", county: "Grand Traverse County", region: "Michigan", country: "United States")

    descriptor = LocationMapRegion.for_result(raw)

    assert_equal "Traverse City", descriptor[:map_region_name]
    assert_equal 'google-components:v1:["locality","united states","michigan","grand traverse county","traverse city"]', descriptor[:map_region_key]
    %w[country administrative_area_level_1 administrative_area_level_2 locality].each do |type|
      incomplete = raw.deep_dup
      incomplete[:address_components].reject! { |item| item[:types].include?(type) }
      assert_empty LocationMapRegion.for_result(incomplete)
    end
  end

  test "namesakes in different counties states and countries do not share a map region" do
    hierarchies = [
      [ "Sangamon County", "Illinois", "United States" ],
      [ "Greene County", "Missouri", "United States" ],
      [ "Other County", "Illinois", "United States" ],
      [ "Sangamon County", "Illinois", "Other Country" ]
    ]
    keys = hierarchies.map do |county, region, country|
      LocationMapRegion.for_result(result(locality: "Springfield", county: county, region: region, country: country)).fetch(:map_region_key)
    end

    assert_equal 4, keys.uniq.size
  end

  test "country short name presence response order and whitespace do not split map regions" do
    one = result(locality: "Traverse City", county: "Grand Traverse County", region: "Michigan", country: "United States")
    two = result(locality: "  Traverse   City ", county: "Grand Traverse County", region: "Michigan", country: "United States", country_code: "US")
    two[:address_components].reverse!

    assert_equal LocationMapRegion.for_result(one), LocationMapRegion.for_result(two)
  end

  test "London in Canada is not inferred to be Greater London" do
    raw = result(locality: "London", county: "Middlesex County", region: "Ontario", country: "Canada", country_code: "CA")
    descriptor = LocationMapRegion.for_result(raw)

    assert_equal "London", descriptor[:map_region_name]
    assert_includes descriptor[:map_region_key], '"locality","canada","ontario","middlesex county"'
    refute_includes descriptor[:map_region_key], '"metro"'
  end

  test "formatted labels or incomplete London hierarchy never infer containment" do
    assert_empty LocationMapRegion.for_result(formatted_address: "Westminster, Greater London, UK")
    assert_empty LocationMapRegion.for_result(result(locality: "London", county: nil, region: "England", country: "United Kingdom"))
    assert_empty LocationMapRegion.for_result(result(locality: nil, county: "Greater London", region: nil, country: "United Kingdom"))
  end

  private

  def result(locality:, county:, region:, country:, country_code: nil)
    components = [
      [ locality, "locality" ], [ county, "administrative_area_level_2" ],
      [ region, "administrative_area_level_1" ], [ country, "country" ]
    ].filter_map do |name, type|
      { long_name: name, types: [ type ] } if name
    end
    components.find { |item| item[:types] == [ "country" ] }[:short_name] = country_code if country_code
    { address_components: components }
  end
end
