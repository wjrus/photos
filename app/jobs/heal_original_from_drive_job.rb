require "fileutils"
require "tempfile"

class HealOriginalFromDriveJob < ApplicationJob
  queue_as :archive

  def perform(file_health_check)
    unless original_file_auto_heal_enabled?
      Rails.logger.warn(
        "Skipping original file heal for check #{file_health_check.id}: " \
        "original file auto-heal is disabled"
      )
      return
    end

    photo = file_health_check.photo
    archive_object = photo.drive_archive_object

    raise "Photo original is not attached" unless photo.original.attached?
    raise "Drive archive is not available" unless archive_object&.archived?
    raise "Drive file id is missing" if archive_object.google_file_id.blank?

    blob = photo.original.blob
    with_original_file_lock(blob) do
      heal_original(file_health_check, photo, archive_object, blob)
    end
  rescue StandardError => error
    file_health_check.update!(status: "heal_failed", error: error.message)
    raise
  end

  private

  def heal_original(file_health_check, photo, archive_object, blob)
    if (actual = verified_local_original(blob, photo))
      mark_current_file_ok!(file_health_check, actual)
      return
    end

    Tempfile.create([ "photos-heal-original", File.extname(photo.original_filename.to_s) ], File.dirname(blob_path(blob)), binmode: true) do |tempfile|
      temp_path = tempfile.path
      tempfile.close

      GoogleDriveArchiveClient.new(photo.owner).download_file(archive_object.google_file_id, temp_path)
      verify_replacement!(photo, blob, tempfile.path)
      replace_blob_file!(blob, temp_path)
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
  end

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

    target_path = blob_path(blob)
    FileUtils.mkdir_p(File.dirname(target_path))
    File.rename(source_path, target_path)
  rescue Errno::EXDEV
    raise "Automatic local replacement requires temporary files on the same filesystem as storage"
  end

  def enqueue_rebuilds(photo)
    ExtractPhotoMetadataJob.perform_later(photo)
    GenerateVideoPreviewJob.perform_later(photo) if photo.video?
    GeneratePhotoDerivativesJob.perform_later(photo) if photo.derivative_media?
  end

  def verified_local_original(blob, photo)
    actual = fingerprint_path(blob_path(blob))
    return unless actual.fetch(:byte_size) == blob.byte_size
    return if blob.checksum.present? && actual.fetch(:md5) != blob.checksum
    return if photo.checksum_sha256.present? && actual.fetch(:sha256) != photo.checksum_sha256

    actual
  rescue Errno::ENOENT
    nil
  end

  def mark_current_file_ok!(file_health_check, actual)
    file_health_check.update!(
      status: "ok",
      actual_byte_size: actual.fetch(:byte_size),
      actual_checksum_md5: actual.fetch(:md5),
      actual_checksum_sha256: actual.fetch(:sha256),
      error: nil
    )
  end

  def fingerprint_path(path)
    raise Errno::ENOENT, path unless File.exist?(path)

    md5 = Digest::MD5.new
    sha256 = Digest::SHA256.new
    byte_size = 0

    File.open(path, "rb") do |file|
      while (chunk = file.read(OriginalFileHealthCheckJob::READ_CHUNK_SIZE))
        byte_size += chunk.bytesize
        md5.update(chunk)
        sha256.update(chunk)
      end
    end

    { byte_size: byte_size, md5: md5.base64digest, sha256: sha256.hexdigest }
  end

  def blob_path(blob)
    raise "Automatic local replacement requires disk storage" unless blob.service.respond_to?(:path_for)

    blob.service.path_for(blob.key)
  end
end
