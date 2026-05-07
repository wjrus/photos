class AlbumDownload < ApplicationRecord
  STATUSES = %w[pending processing ready failed].freeze

  belongs_to :photo_album
  belongs_to :user

  has_one_attached :archive

  validates :status, inclusion: { in: STATUSES }
  validates :filename, presence: true
  validates :total_entries, :processed_entries, numericality: { greater_than_or_equal_to: 0, only_integer: true }

  def pending?
    status == "pending"
  end

  def processing?
    status == "processing"
  end

  def ready?
    status == "ready"
  end

  def failed?
    status == "failed"
  end

  def progress_percent
    return 0 if total_entries.zero?

    ((processed_entries.to_f / total_entries) * 100).clamp(0, 100).round
  end
end
