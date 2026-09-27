require "test_helper"

class PhotoPlaceTest < ActiveSupport::TestCase
  test "equal labels do not merge distinct provider identities" do
    first = resolve(identity_key: "google:town-one", provider: "google", provider_place_id: "town-one")
    second = resolve(identity_key: "google:town-two", provider: "google", provider_place_id: "town-two")

    assert_not_equal first, second
    assert_equal first, resolve(identity_key: "google:town-one")
    assert_equal [ "Same town" ], first.names
  end

  test "fallback identity uses exact stored coordinates instead of names or old grid cells" do
    first = resolve(latitude: "44.762200", longitude: "-85.598000")
    second = resolve(latitude: "44.762300", longitude: "-85.598000")

    assert_not_equal first, second
    assert_equal "coordinate:44.762200,-85.598000", first.identity_key
    assert_equal first, resolve(latitude: "44.7622004", longitude: "-85.5980004")
    assert_equal "coordinate:0.000000,0.000000", resolve(latitude: "-0.0000001", longitude: 0).identity_key
  end

  test "keeps provider response provenance without key fingerprints" do
    place = resolve(raw: { "place_id" => "town", "key_fingerprint" => "private", key_fingerprint: "private" })

    assert_equal({ "place_id" => "town" }, place.raw)
  end

  test "metro map descriptors do not affect canonical identity" do
    first = resolve(identity_key: "google:first", map_region_key: "GB/England/Greater London", map_region_name: "London")
    second = resolve(identity_key: "google:second", map_region_key: "GB/England/Greater London", map_region_name: "London")

    assert_not_equal first, second
    assert_equal first.map_region_key, second.map_region_key
    assert_equal "London", first.map_region_name
    assert_includes first.names, "London"
  end

  test "existing provider identity gains aliases and a missing qualified map region" do
    first = resolve(identity_key: "google:borough", names: [ "Original alias" ], raw: { "place_id" => "borough" })

    enriched = resolve(
      identity_key: "google:borough", name: "Alternative borough name", names: [ "New alias" ],
      map_region_key: "google-components:v1:[\"metro\",\"gb\",\"england\",\"greater london\"]", map_region_name: "London",
      latitude: 51.5, longitude: 0, raw: { "changed" => true }
    )

    assert_equal first, enriched
    assert_equal "Same town", enriched.name
    assert_equal [ "Same town", "Original alias", "Alternative borough name", "New alias", "London" ], enriched.names
    assert_equal "London", enriched.map_region_name
    assert_equal "google-components:v1:[\"metro\",\"gb\",\"england\",\"greater london\"]", enriched.map_region_key
    assert_equal first.raw, enriched.raw
    assert_equal first.latitude, enriched.latitude
    assert_equal first.longitude, enriched.longitude
  end

  test "later incomplete results retain aliases and region without affecting another identity" do
    first = resolve(identity_key: "google:borough", names: [ "Original alias" ], map_region_key: "london-region", map_region_name: "London")
    other = resolve(identity_key: "google:another-borough", names: [ "Other alias" ])

    retained = resolve(identity_key: "google:borough", names: [ "Later alias" ], map_region_name: "Incomplete region")

    assert_equal first, retained
    assert_equal "london-region", retained.map_region_key
    assert_equal "London", retained.map_region_name
    assert_includes retained.names, "Original alias"
    assert_includes retained.names, "Later alias"
    assert_includes retained.names, "London"
    refute_includes retained.names, "Incomplete region"
    assert_nil other.reload.map_region_key
    assert_nil other.map_region_name
    assert_equal [ "Same town", "Other alias" ], other.names
  end

  private

  def resolve(latitude: 40, longitude: -80, **result)
    PhotoPlace.from_geocode!(result: { name: "Same town" }.merge(result), latitude: latitude, longitude: longitude)
  end
end
