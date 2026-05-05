class GeocodePhotoLocationJob < ApplicationJob
  queue_as :maintenance

  THROTTLE_CACHE_KEY = "geocode-photo-location-job/request-throttle".freeze
  THROTTLE_INTERVAL = 1.second

  def perform(location_id, latitude, longitude)
    return reschedule(location_id, latitude, longitude) unless reserve_throttle_slot

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

  def reschedule(location_id, latitude, longitude)
    self.class.set(wait: THROTTLE_INTERVAL).perform_later(location_id, latitude, longitude)
  end

  def reserve_throttle_slot
    last_request_at = Rails.cache.read(THROTTLE_CACHE_KEY)
    return false if last_request_at && last_request_at.to_f > THROTTLE_INTERVAL.ago.to_f

    Rails.cache.write(THROTTLE_CACHE_KEY, Time.current.to_f, expires_in: THROTTLE_INTERVAL)
  end
end
