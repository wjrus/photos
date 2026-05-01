class ChecksumOriginalJob < ApplicationJob
  queue_as :default

  def perform(photo)
    unless photo.original.attached?
      photo.update!(
        checksum_status: "failed",
        checksum_error: "Original is not attached",
        checksum_checked_at: Time.current
      )
      return
    end

    digest = Digest::SHA256.new
    photo.original.blob.open do |file|
      digest.file(file.path)
    end

    photo.update!(
      checksum_sha256: digest.hexdigest,
      checksum_status: "complete",
      checksum_error: nil,
      checksum_checked_at: Time.current
    )
  rescue StandardError => e
    photo.update!(
      checksum_status: "failed",
      checksum_error: e.message,
      checksum_checked_at: Time.current
    )
    raise
  end
end
