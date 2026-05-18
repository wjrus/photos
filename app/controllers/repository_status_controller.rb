class RepositoryStatusController < ApplicationController
  MANAGED_QUEUE_NAMES = %w[
    solid_queue_recurring
    import
    archive
    maintenance
    analysis
    video_previews
    derivatives
    default
  ].freeze

  owner_access_message "Only the owner can see repository status."

  before_action :require_owner!

  def show
    @status_section = status_section
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
    @analysis_status = analysis_status
    @health = health_totals
    @health_timeline = health_timeline
    @last_health_check_at = FileHealthCheck.maximum(:checked_at)
    @recent_checks = latest_checks.includes(:photo).latest_first.limit(12)
    @recent_attention = latest_checks.needs_attention.includes(:photo).latest_first.limit(8)
    @repository_events = RepositoryEvent.latest_first.limit(12)
    @unread_repository_events = RepositoryEvent.unread.count
    @controls = controls
  end

  def create
    case params[:scan_type].presence
    when "baseline"
      OriginalFileHealthPatrolJob.perform_later(batch_size: baseline_batch_size, stale_after: 100.years)
      redirect_to repository_status_redirect_path, notice: "Baseline repository scan queued."
    when "analysis"
      providers = analysis_backfill_providers
      if providers.empty?
        redirect_to repository_status_redirect_path, alert: "Enable at least one local analysis provider first."
      else
        PhotoAnalysisBackfillJob.perform_later(providers: providers, batch_size: analysis_batch_size)
        redirect_to repository_status_redirect_path, notice: "Photo analysis queued for #{providers.join(', ')}."
      end
    else
      OriginalFileHealthPatrolJob.perform_later(batch_size: patrol_batch_size)
      redirect_to repository_status_redirect_path, notice: "Repository patrol queued."
    end
  end

  def update
    case params[:control].presence
    when "original_file_auto_heal"
      AppSetting.set_boolean!(AppSetting::ORIGINAL_FILE_AUTO_HEAL, params[:enabled])
      redirect_to repository_status_redirect_path, notice: "Original file auto-heal #{params[:enabled] == 'true' ? 'enabled' : 'disabled'}."
    when "analysis"
      update_analysis_control
    when "queue"
      update_queue_control
    when "repository_events"
      RepositoryEvent.unread.update_all(read_at: Time.current, updated_at: Time.current)
      redirect_to repository_status_redirect_path, notice: "Repository notifications marked read."
    else
      redirect_to repository_status_redirect_path, alert: "Unknown repository control."
    end
  end

  private

  def status_section
    params[:section].presence_in(%w[overview maintenance analysis queues health activity]) || "overview"
  end

  def repository_status_redirect_path
    section = status_section
    section == "overview" ? repository_status_path : repository_status_path(section: section)
  end

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

  def analysis_batch_size
    Integer(params[:batch_size].presence || ENV.fetch("ANALYSIS_BACKFILL_BATCH_SIZE", PhotoAnalysisBackfillJob::DEFAULT_BATCH_SIZE)).clamp(1, PhotoAnalysisBackfillJob::MAX_BATCH_SIZE)
  rescue ArgumentError
    PhotoAnalysisBackfillJob::DEFAULT_BATCH_SIZE
  end

  def analysis_status
    openclip_model = ENV.fetch("OPENCLIP_MODEL", "ViT-B-32")
    openclip_model_version = ENV.fetch("OPENCLIP_PRETRAINED", "laion2b_s34b_b79k")
    eligible_photos = original_photos.where(restricted: false)
    current_embeddings = PhotoEmbedding.where(provider: "openclip", model: openclip_model, model_version: openclip_model_version)
    run_scope = PhotoAnalysisRun.where(provider: "openclip", model: openclip_model, model_version: openclip_model_version)
    embedded_count = eligible_photos.where(id: current_embeddings.select(:photo_id)).distinct.count
    eligible_count = eligible_photos.distinct.count

    {
      openclip: {
        model: openclip_model,
        model_version: openclip_model_version,
        eligible: eligible_count,
        embedded: embedded_count,
        missing: [ eligible_count - embedded_count, 0 ].max,
        coverage_percent: eligible_count.positive? ? (embedded_count.to_f / eligible_count * 100).round(1) : 100.0,
        run_counts: PhotoAnalysisRun::STATUSES.index_with { |status| run_scope.where(status: status).count },
        latest_errors: PhotoAnalysisRun.where(provider: "openclip").where.not(error: [ nil, "" ]).latest_first.limit(5)
      }
    }
  end

  def analysis_backfill_providers
    requested = Array(params[:providers]).compact_blank.map(&:to_s)
    requested = local_analysis_providers if requested.empty?

    requested & enabled_local_analysis_providers
  end

  def local_analysis_providers
    %w[openclip yolo]
  end

  def enabled_local_analysis_providers
    local_analysis_providers.select do |provider|
      case provider
      when "openclip"
        AppSetting.boolean(AppSetting::ANALYSIS_OPENCLIP_ENABLED, default: false)
      when "yolo"
        AppSetting.boolean(AppSetting::ANALYSIS_YOLO_ENABLED, default: false)
      end
    end
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
      PhotoAnalysisBackfillJob
      PhotoAnalysisOpenclipJob
      PhotoAnalysisYoloJob
      PhotoAnalysisOpenaiJob
    ]
  end

  def storage_status
    service = ActiveStorage::Blob.service
    configured_path = ENV.fetch("PHOTOS_STORAGE_PATH", nil)
    service_root = service.respond_to?(:root) ? service.root.to_s : nil
    root_exists = service_root.present? ? File.directory?(service_root) : nil
    configured_path_exists = configured_path_exists_in_container(configured_path, service_root)
    path_attention = root_exists == false || configured_path_exists == false

    {
      service: Rails.application.config.active_storage.service,
      root: service_root,
      configured_path: configured_path,
      configured_path_exists: configured_path_exists,
      root_exists: root_exists,
      path_attention: path_attention,
      auto_heal: original_file_auto_heal_enabled?,
      auto_heal_source: app_setting_present?(AppSetting::ORIGINAL_FILE_AUTO_HEAL) ? "repository setting" : "app default"
    }
  end

  def configured_path_exists_in_container(configured_path, service_root)
    return nil if configured_path.blank?
    return File.directory?(configured_path) if configured_path == service_root

    nil
  end

  def original_file_auto_heal_enabled?
    AppSetting.boolean(AppSetting::ORIGINAL_FILE_AUTO_HEAL, default: false)
  end

  def app_setting_present?(key)
    AppSetting.exists?(key: key)
  end

  def controls
    paused_queue_names = @pauses.map { |pause| pause.fetch("queue_name") }
    queue_rows = @queues.index_by { |queue| queue.fetch(:name) }

    {
      auto_heal: {
        enabled: original_file_auto_heal_enabled?,
        source: app_setting_present?(AppSetting::ORIGINAL_FILE_AUTO_HEAL) ? "repository setting" : "app default"
      },
      analysis: analysis_controls,
      queues: MANAGED_QUEUE_NAMES.map do |queue_name|
        row = queue_rows[queue_name]
        {
          name: queue_name,
          paused: paused_queue_names.include?(queue_name),
          ready: row&.dig(:counts, :ready).to_i,
          claimed: row&.dig(:counts, :claimed).to_i,
          total: row&.fetch(:total).to_i
        }
      end
    }
  end

  def analysis_controls
    AppSetting::ANALYSIS_BOOLEAN_SETTINGS.map do |key, default|
      {
        key: key,
        label: analysis_control_label(key),
        enabled: AppSetting.boolean(key, default: default),
        source: app_setting_present?(key) ? "repository setting" : "app default"
      }
    end
  end

  def analysis_control_label(key)
    {
      AppSetting::ANALYSIS_OPENCLIP_ENABLED => "OpenCLIP semantic search",
      AppSetting::ANALYSIS_YOLO_ENABLED => "YOLO object detection",
      AppSetting::ANALYSIS_OPENAI_ENABLED => "OpenAI vision enrichment",
      AppSetting::ANALYSIS_OPENAI_PUBLIC_ONLY => "OpenAI public photos only",
      AppSetting::ANALYSIS_OPENAI_REQUIRE_OWNER_CONFIRM => "OpenAI requires owner confirmation"
    }.fetch(key)
  end

  def update_analysis_control
    key = params[:setting_key].to_s
    return redirect_to repository_status_redirect_path, alert: "Unknown analysis setting." unless key.in?(AppSetting::ANALYSIS_BOOLEAN_SETTINGS.keys)

    AppSetting.set_boolean!(key, params[:enabled])
    redirect_to repository_status_redirect_path, notice: "#{analysis_control_label(key)} #{params[:enabled] == 'true' ? 'enabled' : 'disabled'}."
  end

  def update_queue_control
    queue_name = params[:queue_name].to_s
    return redirect_to repository_status_redirect_path, alert: "Unknown queue." unless queue_name.in?(MANAGED_QUEUE_NAMES)

    snapshot = QueueStatusSnapshot.build
    case params[:queue_action].presence
    when "pause"
      snapshot.pause_queue(queue_name)
      redirect_to repository_status_redirect_path, notice: "#{queue_name} paused."
    when "resume"
      snapshot.resume_queue(queue_name)
      redirect_to repository_status_redirect_path, notice: "#{queue_name} resumed."
    else
      redirect_to repository_status_redirect_path, alert: "Unknown queue action."
    end
  end
end
