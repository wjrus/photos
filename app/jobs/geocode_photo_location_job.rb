class GeocodePhotoLocationJob < ApplicationJob
  queue_as :maintenance

  THROTTLE_CACHE_KEY = "geocode-photo-location-job/request-throttle".freeze
  THROTTLE_INTERVAL = 1.second
  THROTTLE_LOCK_KEY = 3_728_581_901
  THROTTLE_CACHE_TTL = 1.hour
  THROTTLE_EARLY_WINDOW = 0.05

  def perform(location_id, latitude, longitude, reserved_at = nil)
    reserved_at ||= reserve_throttle_slot
    wait = reserved_at.to_f - Time.current.to_f
    return reschedule(location_id, latitude, longitude, reserved_at) if wait > THROTTLE_EARLY_WINDOW

    result = LocationReverseGeocoder.new.geocode(latitude: latitude, longitude: longitude)
    unless result&.fetch(:name, nil).present?
      Rails.logger.warn("No place name found for location #{location_id} (#{latitude}, #{longitude})")
      return
    end

    PhotoLocationPlace.upsert(
      {
        location_id: location_id,
        name: result.fetch(:name),
        names: result.fetch(:names, [ result.fetch(:name) ]),
        latitude: latitude,
        longitude: longitude,
        raw: result.fetch(:raw).except(:key_fingerprint),
        geocoded_at: Time.current,
        created_at: Time.current,
        updated_at: Time.current
      },
      unique_by: :index_photo_location_places_on_location_id
    )

    Rails.logger.info("Geocoded photo location #{location_id}: #{result.fetch(:name)} key=#{result.fetch(:key_fingerprint, 'unknown')}")
  end

  private

  def reschedule(location_id, latitude, longitude, reserved_at)
    self.class
      .set(wait_until: Time.zone.at(reserved_at.to_f))
      .perform_later(location_id, latitude, longitude, reserved_at)
  end

  def reserve_throttle_slot
    with_throttle_lock do
      now = Time.current.to_f
      next_at = Rails.cache.read(THROTTLE_CACHE_KEY).to_f
      reserved_at = [ now, next_at ].max

      Rails.cache.write(THROTTLE_CACHE_KEY, reserved_at + THROTTLE_INTERVAL.to_f, expires_in: THROTTLE_CACHE_TTL)
      reserved_at
    end
  end

  def with_throttle_lock
    connection = ActiveRecord::Base.connection
    return yield unless connection.adapter_name == "PostgreSQL"

    connection.execute("SELECT pg_advisory_lock(#{THROTTLE_LOCK_KEY})")
    yield
  ensure
    connection&.execute("SELECT pg_advisory_unlock(#{THROTTLE_LOCK_KEY})") if connection&.adapter_name == "PostgreSQL"
  end
end
