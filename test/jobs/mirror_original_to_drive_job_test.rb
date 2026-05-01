require "test_helper"

class MirrorOriginalToDriveJobTest < ActiveJob::TestCase
  test "records failure when drive folder is not configured" do
    previous_folder_id = ENV["GOOGLE_DRIVE_ARCHIVE_FOLDER_ID"]
    ENV["GOOGLE_DRIVE_ARCHIVE_FOLDER_ID"] = nil
    photo = attached_photo

    assert_raises(RuntimeError) do
      MirrorOriginalToDriveJob.perform_now(photo)
    end

    archive_object = photo.reload.drive_archive_object
    assert_equal "failed", archive_object.status
    assert_includes archive_object.error, "GOOGLE_DRIVE_ARCHIVE_FOLDER_ID"
  ensure
    ENV["GOOGLE_DRIVE_ARCHIVE_FOLDER_ID"] = previous_folder_id
  end

  private

  def attached_photo
    photo = users(:one).photos.new(checksum_sha256: "abc123", checksum_status: "complete")
    photo.original.attach(
      io: File.open(Rails.root.join("public/icon.png")),
      filename: "fixture.png",
      content_type: "image/png"
    )
    photo.save!
    photo
  end
end
