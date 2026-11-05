class OriginalFileHealthPatrolJob < ApplicationJob
  queue_as :maintenance

  DEFAULT_BATCH_SIZE = 100
  DEFAULT_STALE_AFTER = 1.day

  def perform(batch_size: DEFAULT_BATCH_SIZE, stale_after: DEFAULT_STALE_AFTER)
    due_photos(batch_size: batch_size, stale_after: stale_after).each do |photo|
      OriginalFileHealthCheckJob.perform_later(photo)
    end
  end

  private

  def due_photos(batch_size:, stale_after:)
    Photo
      .joins(:original_attachment)
      # Read one timestamp per photo using the (photo_id, checked_at) index.
      # Sorting the entire check history gets more expensive after every patrol.
      .joins(<<~SQL.squish)
        LEFT JOIN LATERAL (
          SELECT checked_at FROM file_health_checks
          WHERE photo_id = photos.id
          ORDER BY checked_at DESC
          LIMIT 1
        ) latest_file_health_checks ON true
      SQL
      .where("latest_file_health_checks.checked_at IS NULL OR latest_file_health_checks.checked_at < ?", stale_after.ago)
      .reorder(Arel.sql("latest_file_health_checks.checked_at ASC NULLS FIRST, photos.byte_size ASC NULLS LAST, photos.id ASC"))
      .limit(batch_size)
  end
end
