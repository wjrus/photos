class MobileUpload < ApplicationRecord
  CHUNK_BYTES = 8.megabytes
  MAX_BYTES = 8.gigabytes
  TTL = 7.days

  belongs_to :device_session
  belongs_to :photo, optional: true
  has_many :mobile_upload_chunks, dependent: :destroy

  validates :client_asset_id, presence: true, length: { maximum: 200 }
  validates :filename, presence: true, length: { maximum: 255 }
  validates :content_type, format: { with: /\A(?:image|video)\/[a-zA-Z0-9.+-]+\z/ }, length: { maximum: 100 }
  validates :byte_size, numericality: { only_integer: true, greater_than: 0, less_than_or_equal_to: MAX_BYTES }
  validates :checksum_sha256, format: { with: /\A[0-9a-f]{64}\z/ }
  validates :expires_at, presence: true
  validate :safe_filename

  def chunk_count
    (byte_size.to_f / CHUNK_BYTES).ceil
  end

  def expected_chunk_size(position)
    [ CHUNK_BYTES, byte_size - position * CHUNK_BYTES ].min
  end

  def complete!
    blob = nil
    with_lock do
      return if completed_at
      raise ActionController::BadRequest, "Upload expired" unless expires_at.future?
      chunks = mobile_upload_chunks.includes(data_attachment: :blob).order(:position).to_a
      raise ActionController::BadRequest, "Upload is incomplete" unless chunks.map(&:position) == (0...chunk_count).to_a
      Tempfile.create([ "mobile-upload-", File.extname(filename) ], binmode: true) do |file|
        digest = Digest::SHA256.new
        chunks.each do |chunk|
          raise ActionController::BadRequest unless chunk.data.attached? && chunk.data.byte_size == expected_chunk_size(chunk.position)
          chunk.data.download do |bytes|
            digest.update(bytes)
            file.write(bytes)
          end
        end
        raise ActionController::BadRequest, "Checksum mismatch" unless digest.hexdigest == checksum_sha256 && file.size == byte_size
        file.rewind
        # Serialize this API's imports per owner so simultaneous devices cannot
        # create duplicate originals after both checking the same checksum.
        owner = device_session.user
        owner.with_lock do
          existing = owner.photos.find_by(checksum_sha256: checksum_sha256)
          unless existing
            blob = ActiveStorage::Blob.create_and_upload!(io: file, filename: filename, content_type: content_type)
          end
          imported = existing || owner.photos.create!(
            original: blob,
            checksum_sha256: checksum_sha256, checksum_status: "complete", checksum_checked_at: Time.current,
            captured_at: captured_at
          )
          update!(photo: imported, duplicate: existing.present?, completed_at: Time.current)
        end
      end
      mobile_upload_chunks.each(&:destroy!)
    end
  rescue StandardError
    blob&.purge unless blob && ActiveStorage::Attachment.exists?(blob_id: blob.id)
    raise
  end

  private

  def safe_filename
    return if filename.present? && File.basename(filename) == filename && !filename.include?("\\") && !filename.match?(/[[:cntrl:]]/)
    errors.add(:filename, "must be a plain filename")
  end
end
