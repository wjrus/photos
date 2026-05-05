class PhotoMetadata < ApplicationRecord
  self.table_name = "photo_metadata"

  EXTRACTION_STATUSES = %w[pending complete unsupported failed].freeze

  belongs_to :photo

  validates :extraction_status, inclusion: { in: EXTRACTION_STATUSES }

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
end
