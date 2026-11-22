require "openssl"

class ChecksumOriginalJob < ApplicationJob
  queue_as :maintenance

  def perform(photo)
    unless photo.original.attached?
      photo.update!(
        checksum_status: "failed",
        checksum_error: "Original is not attached",
        checksum_checked_at: Time.current
      )
      return
    end

    photo.update!(
      checksum_sha256: verified_sha256(photo.original.blob),
      checksum_status: "complete",
      checksum_error: nil,
      checksum_checked_at: Time.current
    )
    MirrorOriginalToDriveJob.perform_later(photo)
  rescue StandardError => e
    photo.update!(
      checksum_status: "failed",
      checksum_error: e.message,
      checksum_checked_at: Time.current
    )
    raise
  end

  private

  def verified_sha256(blob)
    sha256 = Digest::SHA256.new
    # Match Blob#open's integrity check while hashing directly from storage.
    md5 = OpenSSL::Digest::MD5.new unless blob.composed
    blob.download do |chunk|
      md5&.update(chunk)
      sha256.update(chunk)
    end
    raise ActiveStorage::IntegrityError if md5 && md5.base64digest != blob.checksum

    sha256.hexdigest
  end
end
