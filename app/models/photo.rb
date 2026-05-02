class Photo < ApplicationRecord
  VISIBILITIES = %w[private public].freeze
  CHECKSUM_STATUSES = %w[pending complete failed].freeze

  belongs_to :owner, class_name: "User", inverse_of: :photos
  has_one :metadata, class_name: "PhotoMetadata", dependent: :destroy, inverse_of: :photo
  has_one :drive_archive_object, dependent: :destroy
  has_one_attached :original do |attachable|
    attachable.variant :display, resize_to_limit: [ 1800, 1800 ], format: :jpg, saver: { strip: true, quality: 82 }
  end
  has_many_attached :sidecars

  validates :visibility, inclusion: { in: VISIBILITIES }
  validates :checksum_status, inclusion: { in: CHECKSUM_STATUSES }
  validates :original, presence: true
  validate :original_must_be_supported_media
  validate :sidecars_must_be_aae

  before_validation :copy_original_blob_attributes, if: -> { original.attached? }
  before_validation :set_title_from_original, if: -> { title.blank? && original_filename.present? }
  after_create_commit :enqueue_checksum
  after_create_commit :enqueue_metadata_extraction

  scope :visible_to, ->(user) {
    if user&.owner?
      all
    else
      where(visibility: "public")
    end
  }
  scope :stream_order, -> { order(Arel.sql("COALESCE(photos.captured_at, photos.created_at) DESC")) }

  def public?
    visibility == "public"
  end

  def private?
    visibility == "private"
  end

  def publish!
    update!(visibility: "public", published_at: Time.current)
  end

  def unpublish!
    update!(visibility: "private", published_at: nil)
  end

  def checksum_complete?
    checksum_status == "complete"
  end

  def archive_status
    drive_archive_object&.status || "pending"
  end

  def image?
    content_type.to_s.start_with?("image/")
  end

  def video?
    content_type.to_s.start_with?("video/")
  end

  def sidecar_count
    sidecars.attachments.size
  end

  private

  def copy_original_blob_attributes
    self.original_filename = original.filename.to_s
    self.content_type = original.content_type
    self.byte_size = original.byte_size
  end

  def set_title_from_original
    self.title = File.basename(original_filename, ".*").tr("-_", " ").humanize
  end

  def original_must_be_supported_media
    return unless original.attached?
    return if original.content_type.to_s.start_with?("image/", "video/")

    errors.add(:original, "must be an image or video")
  end

  def sidecars_must_be_aae
    sidecars.each do |sidecar|
      next if File.extname(sidecar.filename.to_s).casecmp?(".aae")

      errors.add(:sidecars, "must be Apple .AAE sidecar files")
    end
  end

  def enqueue_checksum
    ChecksumOriginalJob.perform_later(self)
  end

  def enqueue_metadata_extraction
    ExtractPhotoMetadataJob.perform_later(self)
  end
end
