require "test_helper"

class GeocodeMissingPhotoLocationsJobTest < ActiveJob::TestCase
  setup do
    @google_maps_geocoding_api_key = ENV["GOOGLE_MAPS_GEOCODING_API_KEY"]
    ENV["GOOGLE_MAPS_GEOCODING_API_KEY"] = "test-key"
    clear_enqueued_jobs
  end

  teardown do
    ENV["GOOGLE_MAPS_GEOCODING_API_KEY"] = @google_maps_geocoding_api_key
  end

  test "queues geocoding for missing location buckets" do
    photo = attached_photo
    geotag(photo, latitude: 45.3733, longitude: -84.9553)
    clear_enqueued_jobs

    assert_enqueued_with(
      job: GeocodePhotoLocationJob,
      args: [ PhotoLocation.id_for_coordinates(45.3733, -84.9553), 45.3733, -84.9553 ]
    ) do
      GeocodeMissingPhotoLocationsJob.perform_now
    end
  end

  test "skips buckets that already have place names" do
    photo = attached_photo
    geotag(photo, latitude: 45.3733, longitude: -84.9553)
    PhotoLocationPlace.create!(
      location_id: PhotoLocation.id_for_coordinates(45.3733, -84.9553),
      name: "Petoskey, Michigan"
    )
    clear_enqueued_jobs

    assert_no_enqueued_jobs only: GeocodePhotoLocationJob do
      GeocodeMissingPhotoLocationsJob.perform_now
    end
  end

  private

  def attached_photo
    photo = users(:one).photos.new(title: "Petoskey")
    photo.original.attach(
      io: File.open(Rails.root.join("public/icon.png")),
      filename: "petoskey.png",
      content_type: "image/png"
    )
    photo.save!
    photo
  end

  def geotag(photo, latitude:, longitude:)
    photo.create_metadata!(
      extraction_status: "complete",
      latitude: latitude,
      longitude: longitude,
      raw: {}
    )
  end
end
