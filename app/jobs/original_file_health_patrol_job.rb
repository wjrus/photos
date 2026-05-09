class OriginalFileHealthPatrolJob < ApplicationJob
  queue_as :maintenance

  DEFAULT_BATCH_SIZE = 100
  DEFAULT_STALE_AFTER = 30.days

  def perform(batch_size: DEFAULT_BATCH_SIZE, stale_after: DEFAULT_STALE_AFTER)
    due_photos(batch_size: batch_size, stale_after: stale_after).each do |photo|
      OriginalFileHealthCheckJob.perform_later(photo)
    end
  end

  private

  def due_photos(batch_size:, stale_after:)
    latest_checks = FileHealthCheck
      .select("DISTINCT ON (photo_id) file_health_checks.*")
      .order("photo_id, checked_at DESC, id DESC")

    Photo
      .joins(:original_attachment)
      .joins("LEFT JOIN (#{latest_checks.to_sql}) latest_file_health_checks ON latest_file_health_checks.photo_id = photos.id")
      .where("latest_file_health_checks.id IS NULL OR latest_file_health_checks.checked_at < ?", stale_after.ago)
      .stream_order
      .limit(batch_size)
  end
end
