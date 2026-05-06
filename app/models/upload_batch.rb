class UploadBatch < ApplicationRecord
  STATUSES = %w[reviewing committed rolled_back].freeze

  belongs_to :owner, class_name: "User", inverse_of: :upload_batches
  has_many :photos, dependent: :nullify

  validates :status, inclusion: { in: STATUSES }

  scope :reviewing, -> { where(status: "reviewing") }

  def self.active_for(owner)
    reviewing.where(owner: owner).order(created_at: :desc).first_or_create!(owner: owner)
  end

  def commit!
    transaction do
      assert_reviewing!

      update!(status: "committed", committed_at: Time.current)
    end
  end

  def rollback!
    transaction do
      assert_reviewing!

      photos.find_each(&:destroy!)
      update!(status: "rolled_back", rolled_back_at: Time.current)
    end
  end

  def reviewing?
    status == "reviewing"
  end

  def photo_count
    photos.where("content_type LIKE ?", "image/%").count
  end

  def video_count
    photos.where("content_type LIKE ?", "video/%").count
  end

  def summary_counts
    {
      total: photos.count,
      photos: photo_count,
      videos: video_count,
      checksums_complete: photos.where(checksum_status: "complete").count,
      checksums_failed: photos.where(checksum_status: "failed").count,
      metadata_complete: metadata_count("complete"),
      metadata_failed: metadata_count("failed"),
      video_derivatives_ready: video_derivatives_ready_count,
      drive_failures: photos.joins(:drive_archive_object).where(drive_archive_objects: { status: "failed" }).count
    }
  end

  private

  def assert_reviewing!
    return if reviewing?

    errors.add(:status, "is not reviewing")
    raise ActiveRecord::RecordInvalid, self
  end

  def metadata_count(status)
    photos.joins(:metadata).where(photo_metadata: { extraction_status: status }).count
  end

  def video_derivatives_ready_count
    photos
      .where("photos.content_type LIKE ?", "video/%")
      .joins("INNER JOIN active_storage_attachments video_previews ON video_previews.record_type = 'Photo' AND video_previews.record_id = photos.id AND video_previews.name = 'video_preview'")
      .joins("INNER JOIN active_storage_attachments video_displays ON video_displays.record_type = 'Photo' AND video_displays.record_id = photos.id AND video_displays.name = 'video_display'")
      .distinct
      .count
  end
end
