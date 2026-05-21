class GeocodeMissingPhotoLocationsJob < ApplicationJob
  queue_as :maintenance

  DEFAULT_LIMIT = 100
  MAX_LIMIT = 1_000

  def perform(limit: DEFAULT_LIMIT)
    return unless LocationReverseGeocoder.api_key.present?

    missing_location_rows(limit: limit).each do |row|
      location_id = PhotoLocation.id_for_coordinates(row.latitude, row.longitude)
      GeocodePhotoLocationJob.perform_later(location_id, row.latitude, row.longitude)
    end
  end

  private

  def missing_location_rows(limit:)
    rows = PhotoLocation.rows(geotagged_photos, limit: bounded_limit(limit)).to_a
    known_location_ids = PhotoLocationPlace
      .where(location_id: rows.map { |row| PhotoLocation.id_for_coordinates(row.latitude, row.longitude) })
      .pluck(:location_id)

    rows.reject do |row|
      known_location_ids.include?(PhotoLocation.id_for_coordinates(row.latitude, row.longitude))
    end
  end

  def geotagged_photos
    Photo
      .where(restricted: false, archived_at: nil)
      .joins(:metadata)
      .where.not(photo_metadata: { latitude: nil, longitude: nil })
  end

  def bounded_limit(limit)
    Integer(limit).clamp(1, MAX_LIMIT)
  rescue ArgumentError, TypeError
    DEFAULT_LIMIT
  end
end
