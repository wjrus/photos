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

  after_create :record_repository_event, if: :repository_event_status?
  after_update :record_repository_event, if: :saved_change_to_repository_event_status?

  def healthy?
    status.in?(%w[ok healed])
  end

  def needs_attention?
    status.in?(ATTENTION_STATUSES)
  end

  private

  def repository_event_status?
    status.in?(ATTENTION_STATUSES + %w[healed])
  end

  def saved_change_to_repository_event_status?
    saved_change_to_status? && repository_event_status?
  end

  def record_repository_event
    RepositoryEvent.record!(
      category: "file_health",
      event_type: status,
      severity: repository_event_severity,
      message: repository_event_message,
      subject: self,
      data: {
        photo_id: photo_id,
        filename: photo&.original_filename,
        blob_key: blob_key,
        error: error
      }.compact
    )
  end

  def repository_event_severity
    case status
    when "healed"
      "info"
    when "missing", "mismatch"
      "warning"
    else
      "error"
    end
  end

  def repository_event_message
    filename = photo&.original_filename || "Photo #{photo_id}"

    case status
    when "healed"
      "#{filename} was healed from Drive."
    when "missing"
      "#{filename} original file is missing."
    when "mismatch"
      "#{filename} original file failed checksum verification."
    when "heal_failed"
      "#{filename} could not be healed from Drive."
    else
      "#{filename} file health check failed."
    end
  end
end
