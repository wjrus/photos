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
    offsets = [ -0.000001.to_d, 0.to_d, 0.000001.to_d ]
    [ [ "44.775", "-85.575" ], [ "-44.775", "85.575" ], [ "0.075", "-0.075" ], [ "-0.075", "0.075" ] ].each do |latitude, longitude|
      coordinates.concat(offsets.product(offsets).map { |lat_offset, lon_offset| [ latitude.to_d + lat_offset, longitude.to_d + lon_offset ] })
    end
    ids = Photo.insert_all!(coordinates.each_index.map do |index|
      { owner_id: users(:one).id, title: "Synthetic location #{index}", created_at: now, updated_at: now }
    end).rows.flatten
    PhotoMetadata.insert_all!(coordinates.each_with_index.map do |(latitude, longitude), index|
      { photo_id: ids[index], latitude: latitude, longitude: longitude, created_at: now, updated_at: now }
    end)
    @scope = Photo.where(id: ids).joins(:metadata)
  end

  test "indexed coordinate ranges roundtrip canonical ids at signed boundaries and adjacent coordinates" do
    expected_buckets.each do |id, expected|
      assert_equal expected.sort, PhotoLocation.scope_for(@scope, id).pluck(:id).sort, id
    end
    assert_empty PhotoLocation.scope_for(@scope, "100_100")
  end

  test "every geographic cell endpoint assigns each stored coordinate to its canonical bucket" do
    step = BigDecimal("0.000001")
    mismatches = (-7200..7200).flat_map do |boundary_id|
      boundary = boundary_id * BigDecimal("0.025")
      [ boundary - step, boundary, boundary + step ].filter_map do |coordinate|
        next if coordinate < -180 || coordinate > 180

        bucket = PhotoLocation.parse_id(PhotoLocation.id_for_coordinates(coordinate, coordinate)).first
        bounds = PhotoLocation.send(:bucket_bounds, bucket, bucket)
        coordinate unless coordinate >= bounds[:south] && coordinate < bounds[:north]
      end
    end

    assert_empty mismatches, "Every endpoint and its adjacent microdegree must roundtrip the persisted Float-based ID"
  end

  test "location groups use the same canonical ids and counts as indexed filters" do
    geotagged = @scope.merge(PhotoMetadata.geotagged)
    counts = PhotoLocation.rows(geotagged, limit: nil).to_h do |row|
      [ PhotoLocation.id_for(row.latitude_bucket, row.longitude_bucket), row.photo_count.to_i ]
    end

    assert_equal expected_buckets.transform_values(&:size), counts
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

  private

  def expected_buckets
    @scope.pluck(:id, "photo_metadata.latitude", "photo_metadata.longitude").each_with_object({}) do |(id, latitude, longitude), buckets|
      next unless latitude && longitude

      location_id = PhotoLocation.id_for_coordinates(latitude, longitude)
      (buckets[location_id] ||= []) << id
    end
  end
end
