class GoogleTakeoutImportRun < ApplicationRecord
  STATUSES = %w[queued running succeeded failed].freeze

  belongs_to :owner, class_name: "User"

  validates :path, :status, presence: true
  validates :status, inclusion: { in: STATUSES }

  scope :recent, -> { order(created_at: :desc) }

  def running?
    status == "running"
  end

  def queued?
    status == "queued"
  end

  def finished?
    finished_at.present?
  end
end
