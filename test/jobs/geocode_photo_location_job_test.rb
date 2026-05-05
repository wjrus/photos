require "test_helper"

class GeocodePhotoLocationJobTest < ActiveJob::TestCase
  setup do
    @cache_store = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    Rails.cache.clear
  end

  teardown do
    Rails.cache = @cache_store
  end

  test "stores reverse geocoded place name" do
    geocoder = FakeReverseGeocoder.new(
      {
        name: "Traverse City, Michigan",
        names: [ "Traverse City, Michigan", "Traverse City", "Michigan", "United States" ],
        raw: { formatted_address: "Traverse City, MI", key_fingerprint: "AIzaSy...test" },
        key_fingerprint: "AIzaSy...test"
      }
    )

    with_reverse_geocoder(geocoder) { GeocodePhotoLocationJob.perform_now("1790_-3424", 44.7622, -85.5980) }

    place = PhotoLocationPlace.find_by!(location_id: "1790_-3424")
    assert_equal "Traverse City, Michigan", place.name
    assert_equal [ "Traverse City, Michigan", "Traverse City", "Michigan", "United States" ], place.names
    assert_equal "Traverse City, MI", place.raw["formatted_address"]
    refute_includes place.raw, "key_fingerprint"
    assert_equal [ [ 44.7622, -85.5980 ] ], geocoder.calls
  end

  test "rate limits geocode requests" do
    Rails.cache.write(
      GeocodePhotoLocationJob::THROTTLE_CACHE_KEY,
      Time.current.to_f,
      expires_in: GeocodePhotoLocationJob::THROTTLE_INTERVAL,
      unless_exist: true
    )

    assert_enqueued_with(job: GeocodePhotoLocationJob) do
      GeocodePhotoLocationJob.perform_now("1790_-3424", 44.7622, -85.5980)
    end
  end

  class FakeReverseGeocoder
    attr_reader :calls

    def initialize(result)
      @result = result
      @calls = []
    end

    def geocode(latitude:, longitude:)
      calls << [ latitude, longitude ]
      @result
    end
  end

  def with_reverse_geocoder(geocoder)
    LocationReverseGeocoder.singleton_class.alias_method :original_new, :new
    LocationReverseGeocoder.define_singleton_method(:new) { geocoder }
    yield
  ensure
    LocationReverseGeocoder.singleton_class.alias_method :new, :original_new
    LocationReverseGeocoder.singleton_class.remove_method :original_new
  end
end
