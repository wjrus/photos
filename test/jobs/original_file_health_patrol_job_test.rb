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

    queued_photo_ids = enqueued_jobs
      .select { |job| job.fetch(:job) == OriginalFileHealthCheckJob }
      .map { |job| job.fetch(:args).first.fetch("_aj_globalid") }
      .map { |gid| gid.split("/").last.to_i }

    assert_equal [ small.id, medium.id ], queued_photo_ids
  end

  private

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
end
