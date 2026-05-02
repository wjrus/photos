class GoogleTakeoutImport < ApplicationRecord
  STATUSES = %w[pending imported duplicate skipped failed].freeze

  belongs_to :photo, optional: true

  validates :zip_path, :entry_name, :status, presence: true
  validates :entry_name, uniqueness: { scope: :zip_path }
  validates :status, inclusion: { in: STATUSES }
end
