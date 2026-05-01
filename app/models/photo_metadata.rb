class PhotoMetadata < ApplicationRecord
  self.table_name = "photo_metadata"

  EXTRACTION_STATUSES = %w[pending complete unsupported failed].freeze

  belongs_to :photo

  validates :extraction_status, inclusion: { in: EXTRACTION_STATUSES }

  def location?
    latitude.present? && longitude.present?
  end
end
