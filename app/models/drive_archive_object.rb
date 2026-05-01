class DriveArchiveObject < ApplicationRecord
  STATUSES = %w[pending archived failed].freeze

  belongs_to :photo

  validates :status, inclusion: { in: STATUSES }
  validates :photo_id, uniqueness: true

  def archived?
    status == "archived"
  end
end
