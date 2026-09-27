require "test_helper"

class PhotoMetadataTest < ActiveSupport::TestCase
  test "knows when it has a location" do
    metadata = PhotoMetadata.new(latitude: 44.7, longitude: -85.6)

    assert_predicate metadata, :location?
  end

  test "recovers when another worker creates metadata first" do
    photo = attached_photo
    assert_nil photo.metadata
    created_metadata = PhotoMetadata.create!(photo_id: photo.id)

    metadata = PhotoMetadata.for_photo(photo)

    assert_equal created_metadata, metadata
  end

  test "queues reverse geocoding when gps coordinates are stored" do
    with_geocoding_key do
      photo = attached_photo
      metadata = PhotoMetadata.for_photo(photo)

      assert_enqueued_with(
        job: GeocodePhotoLocationJob,
        args: [ photo.id, 44.7622, -85.5980 ]
      ) do
        metadata.update!(latitude: 44.7622, longitude: -85.5980)
      end
    end
  end

  test "legacy cell names do not suppress individual place resolution" do
    with_geocoding_key do
      photo = attached_photo
      location_id = PhotoLocation.id_for_coordinates(44.7622, -85.5980)
      PhotoLocationPlace.create!(location_id: location_id, name: "Traverse City, Michigan")

      assert_enqueued_with(job: GeocodePhotoLocationJob, args: [ photo.id, 44.7622, -85.5980 ]) do
        PhotoMetadata.for_photo(photo).update!(latitude: 44.7622, longitude: -85.5980)
      end
    end
  end

  test "changing automatic coordinates clears the obsolete place and invalidates its bounds" do
    photo = attached_photo
    place = PhotoPlace.create!(identity_key: "google:old", name: "Old place")
    metadata = photo.create_metadata!(latitude: 40, longitude: -80, photo_place: place, location_source: "automatic")
    cells = [ PhotoLocation.id_for_coordinates(40, -80), PhotoLocation.id_for_coordinates(41, -81) ]
    ids = [ PhotoLocation.id_for_place(place), *cells, *cells.map { |id| PhotoLocation.id_for_area(id) } ]
    ids.each { |id| create_bounds(id) }

    metadata.update!(latitude: 41, longitude: -81)

    assert_nil metadata.photo_place_id
    assert_nil metadata.location_source
    assert_empty PhotoLocationBound.where(location_id: ids)
  end

  test "rematching a photo invalidates old and new place bounds without deleting the places" do
    photo = attached_photo
    previous = PhotoPlace.create!(identity_key: "google:previous", name: "Previous")
    replacement = PhotoPlace.create!(identity_key: "google:replacement", name: "Replacement")
    metadata = photo.create_metadata!(latitude: 40, longitude: -80, photo_place: previous, location_source: "automatic")
    ids = [ previous, replacement ].map { |place| PhotoLocation.id_for_place(place) }
    ids.each { |id| create_bounds(id) }

    metadata.update!(photo_place: replacement)

    assert_empty PhotoLocationBound.where(location_id: ids)
    assert PhotoPlace.exists?(previous.id)
    assert PhotoPlace.exists?(replacement.id)
  end

  test "destroying metadata invalidates both its place and coordinate bounds" do
    photo = attached_photo
    place = PhotoPlace.create!(identity_key: "google:removed", name: "Removed place")
    metadata = photo.create_metadata!(latitude: 40, longitude: -80, photo_place: place, location_source: "automatic")
    cell = PhotoLocation.id_for_coordinates(40, -80)
    ids = [ PhotoLocation.id_for_place(place), cell, PhotoLocation.id_for_area(cell) ]
    ids.each { |id| create_bounds(id) }

    metadata.destroy!

    assert_empty PhotoLocationBound.where(location_id: ids)
  end

  private

  def create_bounds(location_id)
    PhotoLocationBound.create!(location_id: location_id, south: 1, north: 2, west: 3, east: 4, photo_count: 1, calculated_at: Time.current)
  end

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
