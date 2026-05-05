class GeocodePhotoLocationJob < ApplicationJob
  queue_as :maintenance

  def perform(location_id, latitude, longitude)
    result = LocationReverseGeocoder.new.geocode(latitude: latitude, longitude: longitude)
    unless result&.fetch(:name, nil).present?
      Rails.logger.warn("No place name found for location #{location_id} (#{latitude}, #{longitude})")
      return
    end

    PhotoLocationPlace.upsert(
      {
        location_id: location_id,
        name: result.fetch(:name),
        latitude: latitude,
        longitude: longitude,
        raw: result.fetch(:raw),
        geocoded_at: Time.current,
        created_at: Time.current,
        updated_at: Time.current
      },
      unique_by: :index_photo_location_places_on_location_id
    )

    Rails.logger.info("Geocoded photo location #{location_id}: #{result.fetch(:name)}")
  end
end
