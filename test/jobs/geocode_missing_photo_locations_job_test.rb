require "test_helper"

class GeocodeMissingPhotoLocationsJobTest < ActiveJob::TestCase
  setup do
    @original_keys = %w[GOOGLE_MAPS_GEOCODING_API_KEY GOOGLE_GEOCODING_API_KEY GOOGLE_MAPS_EMBED_API_KEY].to_h { |key| [ key, ENV[key] ] }
    ENV["GOOGLE_MAPS_GEOCODING_API_KEY"] = "test-key"
    clear_enqueued_jobs
  end

  teardown do
    @original_keys.each { |key, value| ENV[key] = value }
  end

  test "queues each unresolved photo separately with a bounded limit" do
    first = metadata(latitude: 45.3733, longitude: -84.9553)
    second = metadata(latitude: 45.3734, longitude: -84.9554)
    PhotoLocationPlace.create!(location_id: PhotoLocation.id_for_coordinates(first.latitude, first.longitude), name: "Legacy cell name")
    clear_enqueued_jobs

    assert_enqueued_jobs 1, only: GeocodePhotoLocationJob do
      GeocodeMissingPhotoLocationsJob.perform_now(limit: 1)
    end
    job = enqueued_jobs.find { |entry| entry[:job] == GeocodePhotoLocationJob }
    assert_equal [ first.photo_id, second.photo_id ].min, job[:args].first
  end

  test "does not queue assigned or manual or incomplete photos" do
    place = PhotoPlace.create!(identity_key: "google:known", name: "Known place")
    metadata(latitude: 40, longitude: -80).update!(photo_place: place, location_source: "automatic")
    metadata(latitude: 41, longitude: -81).update!(photo_place: place, location_source: "manual")
    metadata(latitude: 42, longitude: nil)
    metadata(latitude: nil, longitude: -82)
    clear_enqueued_jobs

    assert_no_enqueued_jobs only: GeocodePhotoLocationJob do
      GeocodeMissingPhotoLocationsJob.perform_now
    end
  end

  test "restores only explicit legacy manual metadata without an API key" do
    manual = metadata(latitude: 40, longitude: -80)
    manual.update!(raw: {
      "manual_location" => { "source" => "owner", "geocoded_name" => "Owner venue", "address" => "Owner address" },
      "manual_location_geocode" => { "place_id" => "owner-venue" }
    })
    unresolved = metadata(latitude: 41, longitude: -81)
    PhotoLocationPlace.create!(location_id: PhotoLocation.id_for_coordinates(unresolved.latitude, unresolved.longitude), name: "Shared legacy name")
    @original_keys.each_key { |key| ENV[key] = nil }
    clear_enqueued_jobs

    assert_no_enqueued_jobs only: GeocodePhotoLocationJob do
      GeocodeMissingPhotoLocationsJob.perform_now(limit: 1)
    end

    assert_equal "google:owner-venue", manual.reload.photo_place.identity_key
    assert_equal "manual", manual.location_source
    assert_nil unresolved.reload.photo_place_id
  end

  test "refresh includes automatic assignments and preserves manual assignments" do
    place = PhotoPlace.create!(identity_key: "google:known", name: "Known place")
    automatic = metadata(latitude: 40, longitude: -80)
    automatic.update!(photo_place: place, location_source: "automatic")
    metadata(latitude: 41, longitude: -81).update!(photo_place: place, location_source: "manual")
    clear_enqueued_jobs

    assert_enqueued_jobs 1, only: GeocodePhotoLocationJob do
      GeocodeMissingPhotoLocationsJob.perform_now(refresh: true)
    end
    assert_equal automatic.photo_id, enqueued_jobs.find { |entry| entry[:job] == GeocodePhotoLocationJob }[:args].first
    assert PhotoPlace.exists?(place.id)
  end

  test "completed bounded refresh advances past an unchanged automatic assignment" do
    place = PhotoPlace.create!(identity_key: "google:known", name: "Known place")
    first, second = travel_to(2.days.ago) do
      [ metadata(latitude: 40, longitude: -80), metadata(latitude: 41, longitude: -81) ].each do |row|
        row.update!(photo_place: place, location_source: "automatic")
      end
    end
    clear_enqueued_jobs

    GeocodeMissingPhotoLocationsJob.perform_now(limit: 1, refresh: true)
    assert_equal first.photo_id, enqueued_jobs.sole[:args].first
    clear_enqueued_jobs

    geocoder = Object.new
    geocoder.define_singleton_method(:geocode) do |latitude:, longitude:|
      { identity_key: "google:known", name: "Known place" }
    end
    original = LocationReverseGeocoder.method(:new)
    LocationReverseGeocoder.define_singleton_method(:new) { geocoder }
    GeocodePhotoLocationJob.perform_now(first.photo_id, first.latitude, first.longitude, Time.current.to_f, refresh: true)

    assert_equal place.id, first.reload.photo_place_id
    assert_operator first.updated_at, :>, second.updated_at
    GeocodeMissingPhotoLocationsJob.perform_now(limit: 1, refresh: true)
    assert_equal second.photo_id, enqueued_jobs.sole[:args].first
  ensure
    LocationReverseGeocoder.define_singleton_method(:new, original) if original
  end

  private

  def metadata(latitude:, longitude:)
    now = Time.current
    id = Photo.insert_all!([ { owner_id: users(:one).id, title: "Batch photo", created_at: now, updated_at: now } ]).rows.flatten.sole
    PhotoMetadata.create!(photo_id: id, latitude: latitude, longitude: longitude)
  end
end
