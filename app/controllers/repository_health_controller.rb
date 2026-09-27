class RepositoryHealthController < ApplicationController
  owner_access_message "Only the owner can see repository health."

  before_action :require_owner!

  def show
    redirect_to repository_status_path(section: "files")
  end

  def create
    case params[:scan_type].presence
    when "baseline"
      OriginalFileHealthPatrolJob.perform_later(batch_size: baseline_batch_size, stale_after: 100.years)
      redirect_to repository_status_path(section: "files"), notice: "Baseline repository scan queued."
    else
      OriginalFileHealthPatrolJob.perform_later(batch_size: patrol_batch_size)
      redirect_to repository_status_path(section: "files"), notice: "Repository patrol queued."
    end
    RepositoryStatusData.invalidate(current_user.id, "health", "queues")
  end

  private

  def original_photos
    Photo.joins(:original_attachment)
  end

  def never_checked_count
    original_photos.left_outer_joins(:file_health_checks).where(file_health_checks: { id: nil }).count
  end

  def patrol_batch_size
    Integer(params[:batch_size].presence || OriginalFileHealthPatrolJob::DEFAULT_BATCH_SIZE).clamp(1, 1_000)
  rescue ArgumentError
    OriginalFileHealthPatrolJob::DEFAULT_BATCH_SIZE
  end

  def baseline_batch_size
    Integer(params[:batch_size].presence || never_checked_count).clamp(1, 50_000)
  rescue ArgumentError
    never_checked_count.clamp(1, 50_000)
  end
end
