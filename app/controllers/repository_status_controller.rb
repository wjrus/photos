class RepositoryStatusController < ApplicationController
  owner_access_message "Only the owner can see repository status."

  before_action :require_owner!

  def show
    @snapshot = QueueStatusSnapshot.build
    @queue_totals = @snapshot.totals
    @queues = @snapshot.queues
    @job_classes = @snapshot.job_classes.first(12)
    @recent_failures = @snapshot.recent_failures(limit: 8)
    @processes = @snapshot.processes
    @pauses = @snapshot.pauses
    @finished_counts = @snapshot.finished_counts

    @storage = storage_status
    @originals = original_file_totals
    @checksums = Photo.group(:checksum_status).count
    @drive_archives = DriveArchiveObject.group(:status).count
    @derivatives = derivative_totals
    @health = health_totals
    @health_timeline = health_timeline
    @recent_checks = latest_checks.includes(:photo).latest_first.limit(12)
    @recent_attention = latest_checks.needs_attention.includes(:photo).latest_first.limit(8)
  end

  def create
    case params[:scan_type].presence
    when "baseline"
      OriginalFileHealthPatrolJob.perform_later(batch_size: baseline_batch_size, stale_after: 100.years)
      redirect_to repository_status_path, notice: "Baseline repository scan queued."
    else
      OriginalFileHealthPatrolJob.perform_later(batch_size: patrol_batch_size)
      redirect_to repository_status_path, notice: "Repository patrol queued."
    end
  end

  private

  def original_file_totals
    originals = original_photos
    {
      total: originals.count,
      bytes: ActiveStorage::Blob.joins(:attachments).where(active_storage_attachments: { record_type: "Photo", name: "original" }).sum(:byte_size),
      images: originals.where("photos.content_type LIKE ?", "image/%").count,
      videos: originals.where("photos.content_type LIKE ?", "video/%").count,
      public: originals.where(visibility: "public", restricted: false, archived_at: nil).count,
      private: originals.where(visibility: "private", restricted: false, archived_at: nil).count,
      restricted: originals.where(restricted: true).count,
      archived: originals.where.not(archived_at: nil).count
    }
  end

  def original_photos
    Photo.joins(:original_attachment)
  end

  def derivative_totals
    image_total = original_photos.where("photos.content_type LIKE ?", "image/%").count
    video_total = original_photos.where("photos.content_type LIKE ?", "video/%").count
    stream_ready = image_variant_count(:stream)
    display_ready = image_variant_count(:display)
    video_preview_ready = original_photos.joins(:video_preview_attachment).where("photos.content_type LIKE ?", "video/%").count
    video_display_ready = original_photos.joins(:video_display_attachment).where("photos.content_type LIKE ?", "video/%").count

    {
      image_total: image_total,
      stream_ready: stream_ready,
      stream_missing: [ image_total - stream_ready, 0 ].max,
      display_ready: display_ready,
      display_missing: [ image_total - display_ready, 0 ].max,
      video_total: video_total,
      video_preview_ready: video_preview_ready,
      video_preview_missing: [ video_total - video_preview_ready, 0 ].max,
      video_display_ready: video_display_ready,
      video_display_missing: [ video_total - video_display_ready, 0 ].max,
      variant_records: ActiveStorage::VariantRecord.count
    }
  end

  def image_variant_count(variant_name)
    digest = variant_digest(variant_name)
    return 0 unless digest

    Photo
      .joins(original_attachment: { blob: :variant_records })
      .where("photos.content_type LIKE ?", "image/%")
      .where(active_storage_variant_records: { variation_digest: digest })
      .distinct
      .count
  rescue ActiveRecord::ConfigurationError, ActiveRecord::StatementInvalid
    0
  end

  def variant_digest(variant_name)
    sample = original_photos.where("photos.content_type LIKE ?", "image/%").first
    return unless sample&.original&.attached? && sample.original.variable?

    sample.original.variant(variant_name).variation.digest
  rescue ActiveStorage::InvariableError
    nil
  end

  def health_totals
    original_count = original_photos.count
    checked_count = latest_checks.count

    {
      checked: checked_count,
      unchecked: [ original_count - checked_count, 0 ].max,
      checked_percent: original_count.positive? ? (checked_count.to_f / original_count * 100).round(1) : 100.0,
      attention: latest_checks.needs_attention.count,
      stale: latest_checks.where("checked_at < ?", OriginalFileHealthPatrolJob::DEFAULT_STALE_AFTER.ago).count,
      status_counts: latest_checks.group(:status).count,
      jobs: health_job_counts
    }
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

  def health_timeline
    checks = FileHealthCheck.where("checked_at >= ?", 24.hours.ago).pluck(:checked_at, :status)
    buckets = 24.downto(0).map { |hours_ago| hours_ago.hours.ago.beginning_of_hour }.uniq.sort.index_with { Hash.new(0) }

    checks.each do |checked_at, status|
      bucket = checked_at.beginning_of_hour
      buckets[bucket][status] += 1 if buckets.key?(bucket)
    end

    buckets.map do |time, counts|
      {
        label: time.strftime("%-I%P"),
        healthy: counts.fetch("ok", 0) + counts.fetch("healed", 0),
        attention: FileHealthCheck::ATTENTION_STATUSES.sum { |status| counts.fetch(status, 0) }
      }
    end
  end

  def health_job_counts
    counts = QueueStatusSnapshot::EXECUTION_STATES.keys.index_with(0).merge(total: 0)
    return counts unless @snapshot.available?

    @snapshot.job_classes.each do |job_class|
      next unless job_class.fetch(:name).in?(health_job_class_names)

      job_class.fetch(:counts).each { |state, count| counts[state] += count }
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

  def storage_status
    service = ActiveStorage::Blob.service
    configured_path = ENV.fetch("PHOTOS_STORAGE_PATH", nil)
    service_root = service.respond_to?(:root) ? service.root.to_s : nil

    {
      service: Rails.application.config.active_storage.service,
      root: service_root,
      configured_path: configured_path,
      configured_path_exists: configured_path.present? ? File.directory?(configured_path) : nil,
      root_exists: service_root.present? ? File.directory?(service_root) : nil,
      auto_heal: original_file_auto_heal_enabled?
    }
  end

  def original_file_auto_heal_enabled?
    ActiveModel::Type::Boolean.new.cast(ENV.fetch(ApplicationJob::ORIGINAL_FILE_HEALTH_AUTO_HEAL_ENV, "false"))
  end
end
