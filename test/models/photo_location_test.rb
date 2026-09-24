require "test_helper"

class PhotoLocationTest < ActiveSupport::TestCase
  setup do
    now = Time.current
    coordinates = [
      [ "0", "0" ], [ "0.024999", "0.024999" ], [ "0.025", "0.025" ],
      [ "-0.025", "-0.025" ], [ "-0.025001", "-0.025001" ], [ "-0.000001", "-0.000001" ],
      [ "44.762200", "-85.598000" ], [ "44.774999", "-85.575001" ], [ "44.775000", "-85.575000" ],
      [ "90", "180" ], [ "-90", "-180" ], [ nil, "0" ], [ "0", nil ], [ nil, nil ]
    ]
    ids = Photo.insert_all!(coordinates.each_index.map do |index|
      { owner_id: users(:one).id, title: "Synthetic location #{index}", created_at: now, updated_at: now }
    end).rows.flatten
    PhotoMetadata.insert_all!(coordinates.each_with_index.map do |(latitude, longitude), index|
      { photo_id: ids[index], latitude: latitude, longitude: longitude, created_at: now, updated_at: now }
    end)
    @scope = Photo.where(id: ids).joins(:metadata)
  end

  test "coordinate ranges preserve floor buckets across signed boundaries and missing coordinates" do
    %w[0_0 1_1 -1_-1 -2_-2 1790_-3424 1791_-3423 3600_7200 -3600_-7200].each do |id|
      latitude_bucket, longitude_bucket = PhotoLocation.parse_id(id)
      expected = @scope.where(
        "FLOOR(photo_metadata.latitude / 0.025) = ? AND FLOOR(photo_metadata.longitude / 0.025) = ?",
        latitude_bucket, longitude_bucket
      ).pluck(:id)

      assert_equal expected.sort, PhotoLocation.scope_for(@scope, id).pluck(:id).sort, id
    end
  end

  test "combined and named locations preserve visibility and exclude invalid bucket ids" do
    ids = %w[0_0 -1_-1 1790_-3424]
    ids.each { |id| PhotoLocationPlace.create!(location_id: id, name: "Synthetic region") }
    expected = ids.flat_map { |id| PhotoLocation.scope_for(@scope, id).pluck(:id) }.uniq
    assert_equal expected.sort, PhotoLocation.scope_for_ids(@scope, ids + [ "invalid", "place-bad" ]).pluck(:id).sort
    assert_equal expected.sort, PhotoLocation.scope_for(@scope, PhotoLocation.place_id_for_name("Synthetic region")).pluck(:id).sort

    Photo.where(id: expected.first).update_all(restricted: true)
    visible = @scope.merge(Photo.visible_to(users(:one)))
    assert_equal expected.drop(1).sort, PhotoLocation.scope_for_place_name(visible, "Synthetic region").pluck(:id).sort
    assert_empty PhotoLocation.scope_for(@scope, "invalid")
    assert_empty PhotoLocation.scope_for_ids(@scope, [])
  end

  test "SQL place ids match existing coordinate ids including decimal boundaries" do
    metadata = PhotoMetadata.where(photo_id: @scope.select(:id)).order(:photo_id)
    expected = metadata.pluck(:latitude, :longitude).map { |latitude, longitude| PhotoLocation.id_for_coordinates(latitude, longitude) }

    assert_equal expected, metadata.pluck(Arel.sql(PhotoLocation.coordinate_id_sql))
  end
end
