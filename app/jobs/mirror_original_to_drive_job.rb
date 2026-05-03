class MirrorOriginalToDriveJob < ApplicationJob
  queue_as :archive

  def perform(photo)
    archive_object = photo.drive_archive_object || photo.build_drive_archive_object
    archive_object.status = "pending"
    archive_object.error = nil
    archive_object.save!

    drive_file = GoogleDriveArchiveClient.new(photo.owner).upload_photo(photo)

    archive_object.update!(
      status: "archived",
      google_file_id: drive_file.id,
      google_md5_checksum: drive_file.md5_checksum,
      google_size: drive_file.size,
      error: nil,
      archived_at: Time.current,
      verified_at: Time.current
    )
  rescue StandardError => e
    (photo.drive_archive_object || photo.build_drive_archive_object).update!(
      status: "failed",
      error: e.message
    )
    raise
  end
end
