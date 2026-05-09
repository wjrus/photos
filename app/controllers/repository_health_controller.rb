class RepositoryHealthController < ApplicationController
  owner_access_message "Only the owner can see repository health."

  before_action :require_owner!

  def show
    original_count = original_photos.count
    checked_count = latest_checks.count
    @totals = {
      originals: original_count,
      checked: checked_count,
      checked_percent: original_count.positive? ? (checked_count.to_f / original_count * 100).round(1) : 100.0,
      attention: latest_checks.needs_attention.count,
      never_checked: never_checked_count,
      stale: stale_count,
      drive_archived: DriveArchiveObject.where(status: "archived").count
    }
    @status_counts = latest_checks.group(:status).count
    @health_job_counts = health_job_counts
    @recent_checks = latest_checks.includes(:photo).latest_first.limit(25)
    @recent_attention = latest_checks.needs_attention.includes(:photo).latest_first.limit(25)
  end

  def create
    case params[:scan_type].presence
    when "baseline"
      OriginalFileHealthPatrolJob.perform_later(batch_size: baseline_batch_size, stale_after: 100.years)
      redirect_to repository_health_path, notice: "Baseline repository scan queued."
    else
      OriginalFileHealthPatrolJob.perform_later(batch_size: patrol_batch_size)
      redirect_to repository_health_path, notice: "Repository patrol queued."
    end
  end

  private

  def original_photos
    Photo.joins(:original_attachment)
  end

  def latest_checks
    FileHealthCheck.where(id: latest_check_ids)
  end

  def latest_check_ids
    FileHealthCheck
      .select("DISTINCT ON (photo_id) id")
      .order("photo_id, checked_at DESC, id DESC")
  end

  def never_checked_count
    original_photos.left_outer_joins(:file_health_checks).where(file_health_checks: { id: nil }).count
  end

  def stale_count
    latest_checks.where("checked_at < ?", OriginalFileHealthPatrolJob::DEFAULT_STALE_AFTER.ago).count
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

  def health_job_counts
    counts = {
      ready: 0,
      claimed: 0,
      scheduled: 0,
      failed: 0,
      blocked: 0,
      total: 0
    }
    snapshot = QueueStatusSnapshot.build
    return counts unless snapshot.available?

    snapshot.job_classes.each do |job_class|
      next unless job_class.fetch(:name).in?(health_job_class_names)

      job_class.fetch(:counts).each do |state, count|
        counts[state] += count
      end
      counts[:total] += job_class.fetch(:total)
    end
    counts
  end

  def health_job_class_names
    %w[
      OriginalFileHealthPatrolJob
      OriginalFileHealthCheckJob
      HealOriginalFromDriveJob
    ]
  end
end
