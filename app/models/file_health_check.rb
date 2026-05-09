class FileHealthCheck < ApplicationRecord
  STATUSES = %w[ok missing mismatch error healed heal_failed].freeze
  ATTENTION_STATUSES = %w[missing mismatch error heal_failed].freeze

  belongs_to :photo
  belongs_to :active_storage_blob, class_name: "ActiveStorage::Blob"

  validates :status, inclusion: { in: STATUSES }
  validates :blob_key, presence: true
  validates :checked_at, presence: true

  scope :latest_first, -> { order(checked_at: :desc, id: :desc) }
  scope :needs_attention, -> { where(status: ATTENTION_STATUSES) }

  def healthy?
    status.in?(%w[ok healed])
  end

  def needs_attention?
    status.in?(ATTENTION_STATUSES)
  end
end
