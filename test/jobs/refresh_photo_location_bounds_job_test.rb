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
    [ first, second ].each do |photo|
      PhotoLocationPlace.create!(
        location_id: location_id_for(photo),
        name: place_name
      )
    end

    RefreshPhotoLocationBoundsJob.perform_now

    place_bounds = PhotoLocationBound.find_by!(location_id: PhotoLocation.place_id_for_name(place_name))
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
