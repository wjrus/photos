require "test_helper"

class RefreshPhotoLocationBoundsJobTest < ActiveJob::TestCase
  setup do
    @owner = users(:one)
  end

  test "refreshes location cell and place bounds" do
    first = attached_photo(title: "Bounds first")
    second = attached_photo(title: "Bounds second")
    geotag(first, latitude: 36.895894, longitude: -111.526942)
    geotag(second, latitude: 36.921856, longitude: -111.495014)
    place_name = "Colorado River"
    place = assign_photo_place(first, name: place_name)
    assign_photo_place(second, place: place)

    RefreshPhotoLocationBoundsJob.perform_now

    place_bounds = PhotoLocationBound.find_by!(location_id: PhotoLocation.id_for_place(place))
    assert_equal 2, place_bounds.photo_count
    assert_equal BigDecimal("36.895894"), place_bounds.south
    assert_equal BigDecimal("36.921856"), place_bounds.north
    assert_equal BigDecimal("-111.526942"), place_bounds.west
    assert_equal BigDecimal("-111.495014"), place_bounds.east

    assert PhotoLocationBound.exists?(location_id: location_id_for(first))
    assert PhotoLocationBound.exists?(location_id: location_id_for(second))
  end

  test "removes stale bounds when locations disappear" do
    stale = PhotoLocationBound.create!(
      location_id: "1_2",
      south: 1,
      north: 1,
      west: 2,
      east: 2,
      photo_count: 1,
      calculated_at: 1.day.ago
    )

    RefreshPhotoLocationBoundsJob.perform_now

    refute PhotoLocationBound.exists?(stale.id)
  end

  test "incomplete coordinates cannot overwrite zero cell bounds" do
    complete = attached_photo(title: "Both coordinates")
    latitude_only = attached_photo(title: "Latitude only")
    longitude_only = attached_photo(title: "Longitude only")
    geotag(complete, latitude: 0, longitude: 0)
    geotag(latitude_only, latitude: 0, longitude: nil)
    geotag(longitude_only, latitude: nil, longitude: 0)

    RefreshPhotoLocationBoundsJob.perform_now

    bounds = PhotoLocationBound.find_by!(location_id: "0_0")
    assert_equal 1, bounds.photo_count
    assert_equal [ 0, 0, 0, 0 ], bounds.attributes.values_at("south", "north", "west", "east")
    assert_equal 2, PhotoLocationBound.count
    assert_equal 1, PhotoLocationBound.find_by!(location_id: PhotoLocation.id_for_area("0_0")).photo_count
  end

  test "cell and named bounds use the same persisted ids at exact coordinate boundaries" do
    first = attached_photo(title: "Before boundary")
    boundary = attached_photo(title: "At boundary")
    geotag(first, latitude: "44.774999", longitude: "-85.575000")
    geotag(boundary, latitude: "44.775000", longitude: "-85.575000")
    place = assign_photo_place(first, name: "Boundary town")
    assign_photo_place(boundary, place: place)

    RefreshPhotoLocationBoundsJob.perform_now

    [ location_id_for(boundary), PhotoLocation.id_for_place(place) ].each do |id|
      bounds = PhotoLocationBound.find_by!(location_id: id)
      assert_equal 2, bounds.photo_count
      assert_equal BigDecimal("44.774999"), bounds.south
      assert_equal BigDecimal("44.775000"), bounds.north
    end
  end

  private

  def location_id_for(photo)
    metadata = photo.metadata
    PhotoLocation.id_for_coordinates(metadata.latitude, metadata.longitude)
  end

  def geotag(photo, latitude:, longitude:)
    photo.create_metadata!(
      extraction_status: "complete",
      latitude: latitude,
      longitude: longitude,
      raw: {}
    )
  end

  def attached_photo(title:)
    photo = @owner.photos.new(title: title)
    photo.original.attach(
      io: File.open(Rails.root.join("public/icon.png")),
      filename: "#{title.parameterize}.png",
      content_type: "image/png"
    )
    photo.save!
    photo
  end
end
