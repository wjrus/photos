require "test_helper"

class PhotoMetadataTest < ActiveSupport::TestCase
  test "knows when it has a location" do
    metadata = PhotoMetadata.new(latitude: 44.7, longitude: -85.6)

    assert_predicate metadata, :location?
  end

  test "recovers when another worker creates metadata first" do
    photo = attached_photo
    created_metadata = nil
    original_create = PhotoMetadata.method(:create!)

    PhotoMetadata.define_singleton_method(:create!) do |photo:|
      created_metadata = PhotoMetadata.new(photo: photo)
      created_metadata.save!
      raise ActiveRecord::RecordNotUnique, "duplicate metadata"
    end

    metadata = PhotoMetadata.for_photo(photo)

    assert_equal created_metadata, metadata
  ensure
    PhotoMetadata.define_singleton_method(:create!, original_create)
  end

  test "queues reverse geocoding when gps coordinates are stored" do
    with_geocoding_key do
      photo = attached_photo
      metadata = PhotoMetadata.for_photo(photo)

      assert_enqueued_with(
        job: GeocodePhotoLocationJob,
        args: [ PhotoLocation.id_for_coordinates(44.7622, -85.5980), 44.7622, -85.5980 ]
      ) do
        metadata.update!(latitude: 44.7622, longitude: -85.5980)
      end
    end
  end

  test "does not queue reverse geocoding when place is already known" do
    with_geocoding_key do
      photo = attached_photo
      location_id = PhotoLocation.id_for_coordinates(44.7622, -85.5980)
      PhotoLocationPlace.create!(location_id: location_id, name: "Traverse City, Michigan")

      assert_no_enqueued_jobs only: GeocodePhotoLocationJob do
        PhotoMetadata.for_photo(photo).update!(latitude: 44.7622, longitude: -85.5980)
      end
    end
  end

  private

  def with_geocoding_key
    original_key = ENV["GOOGLE_MAPS_GEOCODING_API_KEY"]
    ENV["GOOGLE_MAPS_GEOCODING_API_KEY"] = "test-key"
    yield
  ensure
    ENV["GOOGLE_MAPS_GEOCODING_API_KEY"] = original_key
  end

  def attached_photo
    photo = users(:one).photos.new
    photo.original.attach(
      io: File.open(Rails.root.join("public/icon.png")),
      filename: "fixture.png",
      content_type: "image/png"
    )
    photo.save!
    photo
  end
end
