require "test_helper"

class GeocodePhotoLocationJobTest < ActiveJob::TestCase
  setup do
    @cache_store = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    now = Time.current
    id = Photo.insert_all!([ { owner_id: users(:one).id, title: "Geocode photo", created_at: now, updated_at: now } ]).rows.flatten.sole
    @photo = Photo.find(id)
    @metadata = @photo.create_metadata!(latitude: 44.7622, longitude: -85.5980)
  end

  teardown do
    Rails.cache = @cache_store
  end

  test "assigns the selected photo to an actual place without changing legacy cell labels" do
    legacy = PhotoLocationPlace.create!(location_id: "1790_-3424", name: "Legacy shared label")
    geocoder = FakeReverseGeocoder.new(place_result)

    with_reverse_geocoder(geocoder) { perform_job }

    place = @metadata.reload.photo_place
    assert_equal "Traverse City, Michigan", place.name
    assert_equal "google:traverse-city", place.identity_key
    assert_equal "automatic", @metadata.location_source
    assert_equal "Legacy shared label", legacy.reload.name
    refute_includes place.raw, "key_fingerprint"
    assert_equal [ [ @metadata.latitude, @metadata.longitude ] ], geocoder.calls
  end

  test "ignores old cell jobs and stale coordinates before calling the geocoder" do
    geocoder = FakeReverseGeocoder.new(place_result)
    with_reverse_geocoder(geocoder) do
      GeocodePhotoLocationJob.perform_now("1790_-3424", 44.7622, -85.5980)
      GeocodePhotoLocationJob.perform_now(@photo.id, 45, -85)
    end

    assert_empty geocoder.calls
    assert_nil @metadata.reload.photo_place_id
  end

  test "does not overwrite manual assignments made while the network request is running" do
    manual = PhotoPlace.create!(identity_key: "google:manual", name: "Owner venue")
    geocoder = FakeReverseGeocoder.new(place_result) do
      @metadata.update!(photo_place: manual, location_source: "manual")
    end
    with_reverse_geocoder(geocoder) { perform_job }

    assert_equal manual, @metadata.reload.photo_place
    assert_equal "manual", @metadata.location_source
    refute PhotoPlace.exists?(identity_key: "google:traverse-city")
  end

  test "does not assign a stale response after coordinates change" do
    geocoder = FakeReverseGeocoder.new(place_result) { @metadata.update!(latitude: 45, longitude: -86) }
    with_reverse_geocoder(geocoder) { perform_job }

    assert_nil @metadata.reload.photo_place_id
    refute PhotoPlace.exists?(identity_key: "google:traverse-city")
  end

  test "refresh replaces only an automatic assignment and preserves its previous place record" do
    previous = PhotoPlace.create!(identity_key: "google:previous", name: "Previous automatic place")
    @metadata.update!(photo_place: previous, location_source: "automatic")
    geocoder = FakeReverseGeocoder.new(place_result)
    with_reverse_geocoder(geocoder) do
      perform_job
      assert_empty geocoder.calls
      GeocodePhotoLocationJob.perform_now(@photo.id, @metadata.latitude, @metadata.longitude, refresh: true)
    end

    assert_equal "google:traverse-city", @metadata.reload.photo_place.identity_key
    assert PhotoPlace.exists?(previous.id)
  end

  test "rate limits pending photo lookups" do
    Rails.cache.write(GeocodePhotoLocationJob::THROTTLE_CACHE_KEY, 1.second.from_now.to_f)

    assert_enqueued_with(job: GeocodePhotoLocationJob) { perform_job }
  end

  test "keeps unresolved photos unassigned when lookup fails" do
    with_reverse_geocoder(FakeReverseGeocoder.new(nil)) { perform_job }

    assert_nil @metadata.reload.photo_place_id
  end

  test "failed refresh keeps its timestamp and assignment for retry" do
    previous = PhotoPlace.create!(identity_key: "google:previous", name: "Previous automatic place")
    @metadata.update!(photo_place: previous, location_source: "automatic", updated_at: 2.days.ago)
    updated_at = @metadata.reload.updated_at

    with_reverse_geocoder(FakeReverseGeocoder.new(nil)) do
      GeocodePhotoLocationJob.perform_now(@photo.id, @metadata.latitude, @metadata.longitude, refresh: true)
    end

    assert_equal previous.id, @metadata.reload.photo_place_id
    assert_equal updated_at, @metadata.updated_at
  end

  private

  def perform_job
    GeocodePhotoLocationJob.perform_now(@photo.id, BigDecimal("44.7622"), BigDecimal("-85.5980"))
  end

  def place_result
    {
      name: "Traverse City, Michigan", names: [ "Traverse City", "Michigan", "United States" ],
      identity_key: "google:traverse-city", provider: "google", provider_place_id: "traverse-city", place_type: "locality",
      raw: { "place_id" => "traverse-city", "key_fingerprint" => "private" }
    }
  end

  class FakeReverseGeocoder
    attr_reader :calls

    def initialize(result, &on_call)
      @result = result
      @on_call = on_call
      @calls = []
    end

    def geocode(latitude:, longitude:)
      calls << [ latitude, longitude ]
      @on_call&.call
      @result
    end
  end

  def with_reverse_geocoder(geocoder)
    original = LocationReverseGeocoder.method(:new)
    LocationReverseGeocoder.define_singleton_method(:new) { geocoder }
    yield
  ensure
    LocationReverseGeocoder.define_singleton_method(:new, original)
  end
end
