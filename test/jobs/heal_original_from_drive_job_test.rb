require "test_helper"

class HealOriginalFromDriveJobTest < ActiveJob::TestCase
  test "downloads verified drive copy and replaces corrupt local original" do
    original_new = nil

    with_auto_heal_enabled do
      source_path = Rails.root.join("public/icon.png")
      photo = attached_photo(source_path)
      photo.create_drive_archive_object!(
        status: "archived",
        google_file_id: "drive-file-id",
        archived_at: Time.current
      )
      File.write(storage_path(photo), "corrupt", mode: "wb")
      check = photo.file_health_checks.create!(
        active_storage_blob: photo.original.blob,
        blob_key: photo.original.blob.key,
        status: "mismatch",
        expected_byte_size: photo.original.blob.byte_size,
        expected_checksum_md5: photo.original.blob.checksum,
        expected_checksum_sha256: photo.checksum_sha256,
        actual_byte_size: "corrupt".bytesize,
        checked_at: Time.current
      )
      fake_client = FakeDriveArchiveClient.new(source_path)
      original_new = GoogleDriveArchiveClient.method(:new)
      GoogleDriveArchiveClient.define_singleton_method(:new) { |_user| fake_client }

      assert_enqueued_jobs 2 do
        HealOriginalFromDriveJob.perform_now(check)
      end

      assert_equal File.binread(source_path), File.binread(storage_path(photo))
      assert_equal "healed", check.reload.status
      assert_not_nil check.healed_at
      assert_not_nil photo.drive_archive_object.reload.verified_at
    end
  ensure
    GoogleDriveArchiveClient.define_singleton_method(:new, original_new) if original_new
  end

  test "does not touch storage when auto heal is disabled" do
    source_path = Rails.root.join("public/icon.png")
    photo = attached_photo(source_path)
    photo.create_drive_archive_object!(
      status: "archived",
      google_file_id: "drive-file-id",
      archived_at: Time.current
    )
    File.write(storage_path(photo), "corrupt", mode: "wb")
    check = photo.file_health_checks.create!(
      active_storage_blob: photo.original.blob,
      blob_key: photo.original.blob.key,
      status: "mismatch",
      expected_byte_size: photo.original.blob.byte_size,
      expected_checksum_md5: photo.original.blob.checksum,
      expected_checksum_sha256: photo.checksum_sha256,
      actual_byte_size: "corrupt".bytesize,
      checked_at: Time.current
    )

    HealOriginalFromDriveJob.perform_now(check)

    assert_equal "corrupt", File.binread(storage_path(photo))
    assert_equal "mismatch", check.reload.status
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

  class FakeDriveArchiveClient
    def initialize(source_path)
      @source_path = source_path
    end

    def download_file(_file_id, destination_path)
      FileUtils.cp(@source_path, destination_path)
    end
  end

  def attached_photo(path)
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
