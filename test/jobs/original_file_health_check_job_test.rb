require "test_helper"

class OriginalFileHealthCheckJobTest < ActiveJob::TestCase
  test "records ok when original bytes match stored metadata" do
    photo = attached_photo

    assert_no_enqueued_jobs only: HealOriginalFromDriveJob do
      check = OriginalFileHealthCheckJob.perform_now(photo)

      assert_equal "ok", check.status
      assert_equal photo.original.blob.byte_size, check.actual_byte_size
      assert_equal photo.checksum_sha256, check.actual_checksum_sha256
      assert_nil check.error
    end
  end

  test "records mismatch and queues healing when archived drive copy exists" do
    with_auto_heal_enabled do
      photo = attached_photo
      photo.create_drive_archive_object!(
        status: "archived",
        google_file_id: "drive-file-id",
        archived_at: Time.current
      )
      File.write(storage_path(photo), "wrong bytes", mode: "wb")

      assert_difference "RepositoryEvent.where(severity: 'warning').unread.count", 1 do
        assert_enqueued_with(job: HealOriginalFromDriveJob) do
          check = OriginalFileHealthCheckJob.perform_now(photo)

          assert_equal "mismatch", check.status
          assert_includes check.error, "bytes"
          assert_equal "wrong bytes".bytesize, check.actual_byte_size
        end
      end

      assert_includes RepositoryEvent.latest_first.first.message, "failed checksum"
    end
  end

  test "records missing and queues healing when archived drive copy exists" do
    with_auto_heal_enabled do
      photo = attached_photo
      photo.create_drive_archive_object!(
        status: "archived",
        google_file_id: "drive-file-id",
        archived_at: Time.current
      )
      File.delete(storage_path(photo))

      assert_difference "RepositoryEvent.where(severity: 'warning').unread.count", 1 do
        assert_enqueued_with(job: HealOriginalFromDriveJob) do
          check = OriginalFileHealthCheckJob.perform_now(photo)

          assert_equal "missing", check.status
          assert check.error.present?
        end
      end
    end
  end

  test "records missing without queuing healing when auto heal is disabled" do
    photo = attached_photo
    photo.create_drive_archive_object!(
      status: "archived",
      google_file_id: "drive-file-id",
      archived_at: Time.current
    )
    File.delete(storage_path(photo))

    assert_no_enqueued_jobs only: HealOriginalFromDriveJob do
      check = OriginalFileHealthCheckJob.perform_now(photo)

      assert_equal "missing", check.status
      assert check.error.present?
    end
  end

  private

  def with_auto_heal_enabled
    previous = AppSetting.find_by(key: AppSetting::ORIGINAL_FILE_AUTO_HEAL)&.value
    AppSetting.set_boolean!(AppSetting::ORIGINAL_FILE_AUTO_HEAL, true)
    yield
  ensure
    if previous.nil?
      AppSetting.where(key: AppSetting::ORIGINAL_FILE_AUTO_HEAL).delete_all
    else
      AppSetting.set_boolean!(AppSetting::ORIGINAL_FILE_AUTO_HEAL, previous)
    end
  end

  def attached_photo
    path = Rails.root.join("public/icon.png")
    photo = users(:one).photos.new(
      checksum_sha256: Digest::SHA256.file(path).hexdigest,
      checksum_status: "complete"
    )
    photo.original.attach(io: File.open(path, "rb"), filename: "fixture.png", content_type: "image/png")
    photo.save!
    photo
  end

  def storage_path(photo)
    ActiveStorage::Blob.service.path_for(photo.original.blob.key)
  end
end
