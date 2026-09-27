class GeocodeMissingPhotoLocationsJob < ApplicationJob
  queue_as :maintenance

  DEFAULT_LIMIT = 100
  MAX_LIMIT = 1_000

  def perform(limit: DEFAULT_LIMIT, refresh: false)
    remaining = bounded_limit(limit)
    legacy_manual_metadata.limit(remaining).each do |metadata|
      PhotoManualLocationAssigner.restore!(metadata: metadata)
      remaining -= 1
    end
    return if remaining.zero?
    return unless LocationReverseGeocoder.api_key.present?

    missing_location_rows(limit: remaining, refresh: refresh).each do |row|
      if refresh
        GeocodePhotoLocationJob.perform_later(row.photo_id, row.latitude, row.longitude, refresh: true)
      else
        GeocodePhotoLocationJob.perform_later(row.photo_id, row.latitude, row.longitude)
      end
    end
  end

  private

  def metadata_scope
    PhotoMetadata.geotagged
      .joins(:photo)
      .merge(Photo.where(restricted: false, archived_at: nil))
      .order(:photo_id)
  end

  def legacy_manual_metadata
    metadata_scope.where(photo_place_id: nil)
      .where("photo_metadata.raw->'manual_location'->>'source' = 'owner'")
  end

  def missing_location_rows(limit:, refresh:)
    scope = metadata_scope
      .where(location_source: [ nil, "automatic" ])
      .where("COALESCE(photo_metadata.raw->'manual_location'->>'source', '') != 'owner'")
      .select(:photo_id, :latitude, :longitude)
      .limit(bounded_limit(limit))
    if refresh
      scope.reorder("photo_metadata.updated_at ASC, photo_metadata.photo_id ASC")
    else
      scope.where(photo_place_id: nil)
    end
  end

  def bounded_limit(limit)
    Integer(limit).clamp(1, MAX_LIMIT)
  rescue ArgumentError, TypeError
    DEFAULT_LIMIT
  end
end
