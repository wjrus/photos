class Photo < ApplicationRecord
  VISIBILITIES = %w[private public].freeze
  CHECKSUM_STATUSES = %w[pending complete failed].freeze
  STREAM_PAGE_SIZE = 60
  STREAM_TUPLE_SQL = "(CASE WHEN photos.captured_at IS NULL THEN 0 ELSE 1 END, COALESCE(photos.captured_at, TIMESTAMP '0001-01-01'), photos.created_at, photos.id)".freeze
  STREAM_TUPLE_GREATER_THAN_SQL = "#{STREAM_TUPLE_SQL} > (:has_capture, :captured_at, :created_at, :id)".freeze
  STREAM_TUPLE_LESS_THAN_SQL = "#{STREAM_TUPLE_SQL} < (:has_capture, :captured_at, :created_at, :id)".freeze

  belongs_to :owner, class_name: "User", inverse_of: :photos
  has_one :metadata, class_name: "PhotoMetadata", dependent: :destroy, inverse_of: :photo
  has_one :drive_archive_object, dependent: :destroy
  has_many :photo_album_memberships, dependent: :destroy
  has_many :photo_albums, through: :photo_album_memberships
  has_many :photo_people_tags, dependent: :destroy
  has_many :tagged_users, through: :photo_people_tags, source: :user
  has_one_attached :original do |attachable|
    attachable.variant :stream, resize_to_fill: [ 700, 700 ], format: :jpg, saver: { strip: true, quality: 72 }
    attachable.variant :display, resize_to_limit: [ 1800, 1800 ], format: :jpg, saver: { strip: true, quality: 82 }
  end
  has_one_attached :video_preview
  has_one_attached :video_display
  has_many_attached :sidecars

  validates :visibility, inclusion: { in: VISIBILITIES }
  validates :checksum_status, inclusion: { in: CHECKSUM_STATUSES }
  validates :original, presence: true
  validate :original_must_be_supported_media
  validate :sidecars_must_be_aae

  before_validation :copy_original_blob_attributes, if: -> { original.attached? }
  before_validation :set_title_from_original, if: -> { title.blank? && original_filename.present? }
  after_create_commit :enqueue_checksum, unless: :checksum_complete?
  after_create_commit :enqueue_drive_archive, if: :checksum_complete?
  after_create_commit :enqueue_metadata_extraction
  after_create_commit :enqueue_derivatives, if: :derivative_media?

  scope :visible_to, ->(user) {
    if user&.owner?
      where(restricted: false, archived_at: nil)
    elsif user
      tagged_photo_ids = PhotoPeopleTag.where(user_id: user.id).select(:photo_id)
      where(restricted: false, archived_at: nil).where("photos.visibility = :public_visibility OR photos.id IN (#{tagged_photo_ids.to_sql})", public_visibility: "public")
    else
      where(visibility: "public", restricted: false, archived_at: nil)
    end
  }
  scope :restricted, -> { where(restricted: true) }
  scope :archived, -> { where(restricted: false).where.not(archived_at: nil) }
  scope :not_archived, -> { where(archived_at: nil) }
  scope :stream_order, -> {
    order(Arel.sql("photos.captured_at DESC NULLS LAST, photos.created_at DESC, photos.id DESC"))
  }
  scope :reverse_stream_order, -> {
    reorder(Arel.sql(stream_tuple_order(direction: "ASC", nulls: "FIRST")))
  }
  scope :with_original_variant_records, -> {
    with_attached_video_preview
      .with_attached_video_display
      .with_attached_original
      .includes(original_attachment: { blob: { variant_records: { image_attachment: :blob } } })
  }
  scope :in_map_bounds, ->(bounds) {
    north = bounds[:north]
    south = bounds[:south]
    east = bounds[:east]
    west = bounds[:west]

    if north && south
      where(photo_metadata: { latitude: south..north })
    else
      all
    end.then do |scope|
      if east && west && east < west
        scope.where("photo_metadata.longitude >= :west OR photo_metadata.longitude <= :east", west: west, east: east)
      elsif east && west
        scope.where(photo_metadata: { longitude: west..east })
      else
        scope
      end
    end
  }

  def self.before_stream_cursor(cursor)
    captured_at, created_at, id = decode_stream_cursor(cursor)
    return all unless created_at && id

    if captured_at
      where(
        "photos.captured_at < :captured_at OR
          (photos.captured_at = :captured_at AND photos.created_at < :created_at) OR
          (photos.captured_at = :captured_at AND photos.created_at = :created_at AND photos.id < :id) OR
          photos.captured_at IS NULL",
        captured_at: captured_at,
        created_at: created_at,
        id: id
      )
    else
      where(
        "photos.captured_at IS NULL AND
          (photos.created_at < :created_at OR
            (photos.created_at = :created_at AND photos.id < :id))",
        created_at: created_at,
        id: id
      )
    end
  end

  def self.after_stream_cursor(cursor)
    captured_at, created_at, id = decode_stream_cursor(cursor)
    return none unless created_at && id

    where(
      STREAM_TUPLE_GREATER_THAN_SQL,
      {
        has_capture: captured_at.present? ? 1 : 0,
        captured_at: captured_at || Time.zone.local(1, 1, 1),
        created_at: created_at,
        id: id
      }
    )
  end

  def self.stream_before(photo)
    stream_tuple_greater_than(photo).reorder(Arel.sql(stream_tuple_order(direction: "ASC", nulls: "FIRST"))).first
  end

  def self.stream_after(photo)
    stream_tuple_less_than(photo).reorder(Arel.sql(stream_tuple_order(direction: "DESC", nulls: "LAST"))).first
  end

  def self.decode_stream_cursor(cursor)
    captured_at, created_at, id = cursor.to_s.split("_", 3)
    [
      captured_at == "none" ? nil : Time.zone.iso8601(captured_at),
      Time.zone.iso8601(created_at),
      Integer(id)
    ]
  rescue ArgumentError, TypeError
    [ nil, nil, nil ]
  end

  def self.stream_cursor_before(captured_at)
    [
      captured_at.utc.iso8601(6),
      Time.utc(9999, 12, 31, 23, 59, 59).iso8601(6),
      9_999_999_999
    ].join("_")
  end

  def stream_cursor
    "#{captured_at&.utc&.iso8601(6) || 'none'}_#{created_at.utc.iso8601(6)}_#{id}"
  end

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

  def archived?
    archived_at.present?
  end

  def archive!
    update!(archived_at: Time.current)
  end

  def restore!
    update!(archived_at: nil)
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

  def derivative_media?
    image? || video?
  end

  def video_derivatives_ready?
    video? && video_preview.attached? && video_display.attached?
  end

  def sidecar_count
    sidecars.attachments.size
  end

  def processed_original_variant_record(variant_name)
    return unless image? && original.attached?

    variation_digest = original.variant(variant_name).variation.digest
    variant_records = original.blob.variant_records

    if variant_records.loaded?
      variant_records.find { |record| record.variation_digest == variation_digest }
    else
      variant_records.find_by(variation_digest: variation_digest)
    end
  end

  private

  def self.stream_tuple_greater_than(photo)
    where(
      STREAM_TUPLE_GREATER_THAN_SQL,
      stream_tuple_values(photo)
    )
  end

  def self.stream_tuple_less_than(photo)
    where(
      STREAM_TUPLE_LESS_THAN_SQL,
      stream_tuple_values(photo)
    )
  end

  def self.stream_tuple_order(direction:, nulls:)
    "CASE WHEN photos.captured_at IS NULL THEN 0 ELSE 1 END #{direction}, photos.captured_at #{direction} NULLS #{nulls}, photos.created_at #{direction}, photos.id #{direction}"
  end

  def self.stream_tuple_values(photo)
    {
      has_capture: photo.captured_at.present? ? 1 : 0,
      captured_at: photo.captured_at || Time.zone.local(1, 1, 1),
      created_at: photo.created_at,
      id: photo.id
    }
  end

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

  def enqueue_drive_archive
    MirrorOriginalToDriveJob.perform_later(self)
  end

  def enqueue_metadata_extraction
    ExtractPhotoMetadataJob.perform_later(self)
  end

  def enqueue_derivatives
    GeneratePhotoDerivativesJob.perform_later(self)
  end
end
