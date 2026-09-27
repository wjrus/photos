class GeocodePhotoLocationJob < ApplicationJob
  queue_as :maintenance

  THROTTLE_CACHE_KEY = "geocode-photo-location-job/request-throttle".freeze
  THROTTLE_INTERVAL = 1.second
  THROTTLE_LOCK_KEY = 3_728_581_901
  THROTTLE_CACHE_TTL = 1.hour
  THROTTLE_EARLY_WINDOW = 0.05

  def perform(photo_id, latitude, longitude, reserved_at = nil, refresh: false)
    # Old queued jobs used shared coordinate-cell IDs. They cannot safely name
    # individual photos and are intentionally discarded during the transition.
    return unless photo_id.to_s.match?(/\A[1-9]\d*\z/)

    metadata = PhotoMetadata.includes(:photo).find_by(photo_id: photo_id)
    return unless assignable?(metadata, latitude, longitude, refresh: refresh)
    previous_place_id = metadata.photo_place_id

    reserved_at ||= reserve_throttle_slot
    wait = reserved_at.to_f - Time.current.to_f
    return reschedule(photo_id, latitude, longitude, reserved_at, refresh: refresh) if wait > THROTTLE_EARLY_WINDOW

    result = LocationReverseGeocoder.new.geocode(latitude: latitude, longitude: longitude)
    unless result&.fetch(:name, nil).present?
      Rails.logger.warn("No place name found for photo #{photo_id}")
      return
    end

    metadata.with_lock do
      return unless assignable?(metadata, latitude, longitude, refresh: refresh)
      return unless metadata.photo_place_id == previous_place_id

      place = PhotoPlace.from_geocode!(result: result, latitude: metadata.latitude, longitude: metadata.longitude)
      attributes = { photo_place: place, location_source: "automatic" }
      # Successful unchanged matches still advance the next bounded refresh.
      attributes[:updated_at] = Time.current if refresh
      metadata.update!(attributes)
    end
  end

  private

  def assignable?(metadata, latitude, longitude, refresh:)
    return false unless metadata&.location?
    return false if metadata.manual_location? || (metadata.photo_place_id.present? && !refresh)
    return false if metadata.photo.restricted? || metadata.photo.archived?

    metadata.latitude == BigDecimal(latitude.to_s).round(6) && metadata.longitude == BigDecimal(longitude.to_s).round(6)
  rescue ArgumentError
    false
  end

  def reschedule(photo_id, latitude, longitude, reserved_at, refresh:)
    self.class
      .set(wait_until: Time.zone.at(reserved_at.to_f))
      .perform_later(photo_id, latitude, longitude, reserved_at, refresh: refresh)
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
