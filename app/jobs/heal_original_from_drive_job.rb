require "fileutils"
require "tempfile"

class HealOriginalFromDriveJob < ApplicationJob
  queue_as :archive

  def perform(file_health_check)
    photo = file_health_check.photo
    archive_object = photo.drive_archive_object

    raise "Photo original is not attached" unless photo.original.attached?
    raise "Drive archive is not available" unless archive_object&.archived?
    raise "Drive file id is missing" if archive_object.google_file_id.blank?

    blob = photo.original.blob

    Tempfile.create([ "photos-heal-original", File.extname(photo.original_filename.to_s) ], binmode: true) do |tempfile|
      GoogleDriveArchiveClient.new(photo.owner).download_file(archive_object.google_file_id, tempfile.path)
      verify_replacement!(photo, blob, tempfile.path)
      replace_blob_file!(blob, tempfile.path)
    end

    file_health_check.update!(
      status: "healed",
      actual_byte_size: blob.byte_size,
      actual_checksum_md5: blob.checksum,
      actual_checksum_sha256: photo.checksum_sha256,
      error: nil,
      healed_at: Time.current
    )

    archive_object.update!(verified_at: Time.current, error: nil)
    enqueue_rebuilds(photo)
  rescue StandardError => error
    file_health_check.update!(status: "heal_failed", error: error.message)
    raise
  end

  private

  def verify_replacement!(photo, blob, path)
    actual_size = File.size(path)
    raise "Downloaded file has #{actual_size} bytes, expected #{blob.byte_size}" unless actual_size == blob.byte_size

    actual_md5 = Digest::MD5.file(path).base64digest
    raise "Downloaded file failed Active Storage checksum verification" if blob.checksum.present? && actual_md5 != blob.checksum

    actual_sha256 = Digest::SHA256.file(path).hexdigest
    if photo.checksum_sha256.present? && actual_sha256 != photo.checksum_sha256
      raise "Downloaded file failed SHA-256 verification"
    end
  end

  def replace_blob_file!(blob, source_path)
    raise "Automatic local replacement requires disk storage" unless blob.service.respond_to?(:path_for)

    target_path = blob.service.path_for(blob.key)
    FileUtils.mkdir_p(File.dirname(target_path))
    FileUtils.mv(source_path, target_path)
  end

  def enqueue_rebuilds(photo)
    ExtractPhotoMetadataJob.perform_later(photo)
    GenerateVideoPreviewJob.perform_later(photo) if photo.video?
    GeneratePhotoDerivativesJob.perform_later(photo) if photo.derivative_media?
  end
end
