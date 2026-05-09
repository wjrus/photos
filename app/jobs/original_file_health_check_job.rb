class OriginalFileHealthCheckJob < ApplicationJob
  queue_as :maintenance

  READ_CHUNK_SIZE = 4.megabytes

  def perform(photo, heal: true)
    unless photo.original.attached?
      Rails.logger.warn("Skipping file health check for photo #{photo.id}: original is not attached")
      return
    end

    blob = photo.original.blob
    check = build_check(photo, blob)
    actual = fingerprint(blob)

    check.actual_byte_size = actual.fetch(:byte_size)
    check.actual_checksum_md5 = actual.fetch(:md5)
    check.actual_checksum_sha256 = actual.fetch(:sha256)

    if check.expected_byte_size != check.actual_byte_size
      check.status = "mismatch"
      check.error = "Expected #{check.expected_byte_size} bytes, found #{check.actual_byte_size} bytes"
    elsif check.expected_checksum_sha256.present? && check.expected_checksum_sha256 != check.actual_checksum_sha256
      check.status = "mismatch"
      check.error = "SHA-256 checksum mismatch"
    elsif check.expected_checksum_md5.present? && check.expected_checksum_md5 != check.actual_checksum_md5
      check.status = "mismatch"
      check.error = "Active Storage checksum mismatch"
    else
      check.status = "ok"
      check.error = nil
    end

    check.save!
    maybe_enqueue_heal(check) if heal
    check
  rescue ActiveStorage::FileNotFoundError, Errno::ENOENT => error
    check ||= build_check(photo, blob || photo.original.blob)
    check.status = "missing"
    check.error = error.message
    check.save!
    maybe_enqueue_heal(check) if heal
    check
  rescue StandardError => error
    check ||= photo.original.attached? ? build_check(photo, photo.original.blob) : nil
    if check
      check.status = "error"
      check.error = error.message
      check.save!
      maybe_enqueue_heal(check) if heal
    end
    raise
  end

  private

  def build_check(photo, blob)
    FileHealthCheck.new(
      photo: photo,
      active_storage_blob: blob,
      blob_key: blob.key,
      status: "error",
      expected_byte_size: blob.byte_size,
      expected_checksum_md5: blob.checksum,
      expected_checksum_sha256: photo.checksum_sha256,
      checked_at: Time.current
    )
  end

  def fingerprint(blob)
    if blob.service.respond_to?(:path_for)
      fingerprint_path(blob.service.path_for(blob.key))
    else
      fingerprint_download(blob)
    end
  end

  def fingerprint_path(path)
    raise Errno::ENOENT, path unless File.exist?(path)

    md5 = Digest::MD5.new
    sha256 = Digest::SHA256.new
    byte_size = 0

    File.open(path, "rb") do |file|
      while (chunk = file.read(READ_CHUNK_SIZE))
        byte_size += chunk.bytesize
        md5.update(chunk)
        sha256.update(chunk)
      end
    end

    { byte_size: byte_size, md5: md5.base64digest, sha256: sha256.hexdigest }
  end

  def fingerprint_download(blob)
    md5 = Digest::MD5.new
    sha256 = Digest::SHA256.new
    byte_size = 0

    blob.service.download(blob.key) do |chunk|
      byte_size += chunk.bytesize
      md5.update(chunk)
      sha256.update(chunk)
    end

    { byte_size: byte_size, md5: md5.base64digest, sha256: sha256.hexdigest }
  end

  def maybe_enqueue_heal(check)
    return unless check.needs_attention?
    archive_object = check.photo.drive_archive_object
    return unless archive_object&.archived?
    return if archive_object.google_file_id.blank?

    HealOriginalFromDriveJob.perform_later(check)
  end
end
