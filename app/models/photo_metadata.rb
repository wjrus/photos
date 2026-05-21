class PhotoMetadata < ApplicationRecord
  self.table_name = "photo_metadata"

  EXTRACTION_STATUSES = %w[pending complete unsupported failed].freeze

  belongs_to :photo

  validates :extraction_status, inclusion: { in: EXTRACTION_STATUSES }

  after_commit :enqueue_location_geocoding, if: :location_coordinates_changed?

  def self.for_photo(photo)
    photo.metadata || create!(photo: photo)
  rescue ActiveRecord::RecordNotUnique
    photo.association(:metadata).reset
    photo.metadata || find_by!(photo: photo)
  end

  def location?
    latitude.present? && longitude.present?
  end

  def video?
    video_codec.present? || audio_codec.present? || video_container.present? || video_duration.present?
  end

  private

  def location_coordinates_changed?
    previous_changes.key?("latitude") || previous_changes.key?("longitude")
  end

  def enqueue_location_geocoding
    return unless location?
    return unless LocationReverseGeocoder.api_key.present?

    location_id = PhotoLocation.id_for_coordinates(latitude, longitude)
    place = PhotoLocationPlace.find_by(location_id: location_id)
    return if place.present? && !place.plus_code_name?

    GeocodePhotoLocationJob.perform_later(location_id, latitude, longitude)
  end
end
