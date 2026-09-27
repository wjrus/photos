require "test_helper"

class PhotoManualLocationAssignerTest < ActiveSupport::TestCase
  setup do
    now = Time.current
    ids = Photo.insert_all!(2.times.map { |i| { owner_id: users(:one).id, title: "Location #{i}", created_at: now, updated_at: now } }).rows.flatten
    @selected, @neighbor = Photo.find(ids).sort_by(&:id)
  end

  test "manual assignment affects only the selected photo even within one old cell" do
    existing = PhotoPlace.create!(identity_key: "google:neighbor", name: "Neighbor venue")
    @neighbor.create_metadata!(latitude: "44.762300", longitude: "-85.598000", photo_place: existing, location_source: "automatic")
    legacy = PhotoLocationPlace.create!(location_id: "1790_-3424", name: "Legacy label")

    metadata = PhotoManualLocationAssigner.assign!(photo: @selected, address: "Selected venue", result: {
      latitude: "44.762200", longitude: "-85.598000", name: "Selected venue", identity_key: "google:selected"
    })

    assert_equal "manual", metadata.location_source
    assert_equal "Selected venue", metadata.photo_place.name
    assert_equal existing, @neighbor.reload.metadata.photo_place
    assert_equal "Legacy label", legacy.reload.name
  end

  test "coordinate fallback uses persisted precision and manual assignment rolls back on failure" do
    metadata = PhotoManualLocationAssigner.assign!(photo: @selected, address: "Rounded location", result: {
      latitude: "0.0249996", longitude: "-0.0250004", name: "Rounded location"
    })
    assert_equal BigDecimal("0.025000"), metadata.latitude
    assert_equal "coordinate:0.025000,-0.025000", metadata.photo_place.identity_key
    previous_place = metadata.photo_place

    assert_raises(ActiveRecord::RecordInvalid) do
      PhotoManualLocationAssigner.assign!(photo: @selected, address: "Invalid", result: {
        latitude: 50, longitude: -90, name: "", identity_key: "google:invalid"
      })
    end
    assert_equal BigDecimal("0.025000"), metadata.reload.latitude
    assert_equal previous_place, metadata.photo_place
  end

  test "restores legacy manual metadata without trusting shared cell names" do
    metadata = @selected.create_metadata!(latitude: 40, longitude: -80, raw: {
      "manual_location" => { "source" => "owner", "geocoded_name" => "Explicit venue", "address" => "Owner address" },
      "manual_location_geocode" => {
        "place_id" => "actual-venue", "types" => [ "premise" ],
        "address_components" => [
          { "long_name" => "United Kingdom", "short_name" => "GB", "types" => [ "country" ] },
          { "long_name" => "England", "types" => [ "administrative_area_level_1" ] },
          { "long_name" => "Greater London", "types" => [ "administrative_area_level_2" ] }
        ]
      }
    })
    PhotoLocationPlace.create!(location_id: PhotoLocation.id_for_coordinates(40, -80), name: "Wrong cell label")

    place = PhotoManualLocationAssigner.restore!(metadata: metadata)

    assert_equal "Explicit venue", place.name
    assert_equal "google:actual-venue", place.identity_key
    assert_equal "manual", metadata.reload.location_source
    assert_equal place, metadata.photo_place
    assert_equal "London", place.map_region_name
  end

  test "legacy missing-ID and plus-code results stay coordinate identities" do
    [ { "types" => [ "street_address" ] }, { "types" => [ "plus_code" ], "place_id" => "plus-code-provider-id" } ].each_with_index do |raw, index|
      photo = [ @selected, @neighbor ][index]
      metadata = photo.create_metadata!(latitude: 40 + index, longitude: -80, raw: {
        "manual_location" => { "source" => "owner", "geocoded_name" => "Owner label #{index}" },
        "manual_location_geocode" => raw
      })

      place = PhotoManualLocationAssigner.restore!(metadata: metadata)

      assert_equal "coordinate", place.place_type
      assert_match(/\Acoordinate:/, place.identity_key)
      assert_nil place.provider_place_id
      assert_equal "Owner label #{index}", place.name
    end
  end
end
