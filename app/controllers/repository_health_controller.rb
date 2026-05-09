class RepositoryHealthController < ApplicationController
  owner_access_message "Only the owner can see repository health."

  before_action :require_owner!

  def show
    @totals = {
      photos: Photo.count,
      checked: latest_checks.count,
      attention: latest_checks.needs_attention.count,
      never_checked: never_checked_count,
      drive_archived: DriveArchiveObject.where(status: "archived").count
    }
    @status_counts = latest_checks.group(:status).count
    @recent_checks = latest_checks.includes(:photo).latest_first.limit(25)
    @recent_attention = latest_checks.needs_attention.includes(:photo).latest_first.limit(25)
  end

  def create
    OriginalFileHealthPatrolJob.perform_later(batch_size: patrol_batch_size)
    redirect_to repository_health_path, notice: "Repository patrol queued."
  end

  private

  def latest_checks
    FileHealthCheck.where(id: latest_check_ids)
  end

  def latest_check_ids
    FileHealthCheck
      .select("DISTINCT ON (photo_id) id")
      .order("photo_id, checked_at DESC, id DESC")
  end

  def never_checked_count
    Photo.left_outer_joins(:file_health_checks).where(file_health_checks: { id: nil }).count
  end

  def patrol_batch_size
    Integer(params[:batch_size].presence || OriginalFileHealthPatrolJob::DEFAULT_BATCH_SIZE).clamp(1, 1_000)
  rescue ArgumentError
    OriginalFileHealthPatrolJob::DEFAULT_BATCH_SIZE
  end
end
