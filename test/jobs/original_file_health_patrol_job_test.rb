require "test_helper"

class OriginalFileHealthPatrolJobTest < ActiveJob::TestCase
  test "queues due originals from smallest to largest" do
    large = attached_photo(title: "Large original")
    small = attached_photo(title: "Small original")
    medium = attached_photo(title: "Medium original")
    large.update_columns(byte_size: 300)
    small.update_columns(byte_size: 100)
    medium.update_columns(byte_size: 200)
    clear_enqueued_jobs

    OriginalFileHealthPatrolJob.perform_now(batch_size: 2)

    assert_equal [ small.id, medium.id ], queued_photo_ids
  end

  test "skips originals checked inside the patrol window" do
    fresh = attached_photo(title: "Fresh original")
    stale = attached_photo(title: "Stale original")
    record_check(fresh, checked_at: 12.hours.ago)
    record_check(stale, checked_at: 2.days.ago)
    clear_enqueued_jobs

    OriginalFileHealthPatrolJob.perform_now(batch_size: 10)

    assert_equal [ stale.id ], queued_photo_ids
  end

  test "rotates checked originals by oldest check first" do
    oldest = attached_photo(title: "Oldest original")
    newer = attached_photo(title: "Newer original")
    never_checked = attached_photo(title: "Never checked original")
    record_check(oldest, checked_at: 3.days.ago)
    record_check(newer, checked_at: 2.days.ago)
    clear_enqueued_jobs

    OriginalFileHealthPatrolJob.perform_now(batch_size: 3)

    assert_equal [ never_checked.id, oldest.id, newer.id ], queued_photo_ids
  end

  private

  def queued_photo_ids
    enqueued_jobs
      .select { |job| job.fetch(:job) == OriginalFileHealthCheckJob }
      .map { |job| job.fetch(:args).first.fetch("_aj_globalid") }
      .map { |gid| gid.split("/").last.to_i }
  end

  def attached_photo(title:)
    photo = users(:one).photos.new(title: title)
    photo.original.attach(
      io: File.open(Rails.root.join("public/icon.png"), "rb"),
      filename: "#{title.parameterize}.png",
      content_type: "image/png"
    )
    photo.save!
    photo
  end

  def record_check(photo, checked_at:)
    FileHealthCheck.create!(
      photo: photo,
      active_storage_blob: photo.original.blob,
      blob_key: photo.original.blob.key,
      status: "ok",
      expected_byte_size: photo.original.blob.byte_size,
      actual_byte_size: photo.original.blob.byte_size,
      expected_checksum_md5: photo.original.blob.checksum,
      actual_checksum_md5: photo.original.blob.checksum,
      checked_at: checked_at
    )
  end
end
