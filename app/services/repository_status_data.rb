# Owner-only dashboard data. Cache data, never HTML containing session-specific forms.
# Each panel has a separate lifetime; page navigation does not build a snapshot.
class RepositoryStatusData
  INTERVALS = { "library" => 300, "maintenance" => 300, "health" => 60, "analysis" => 60, "queues" => 20, "activity" => 60 }.freeze
  MANAGED_QUEUE_NAMES = %w[solid_queue_recurring import archive maintenance analysis vision video_previews derivatives default].freeze
  HEALTH_JOB_CLASSES = %w[OriginalFileHealthPatrolJob OriginalFileHealthCheckJob HealOriginalFromDriveJob].freeze

  def self.cache_key(owner_id, panel)
    [ "repository-status/v1", owner_id, panel ]
  end

  def self.invalidate(owner_id, *panels)
    panels.each { |panel| Rails.cache.delete(cache_key(owner_id, panel.to_s)) }
  end

  def initialize(owner_id:)
    @owner_id = owner_id
  end

  def fetch(panel, force: false)
    interval = INTERVALS.fetch(panel)
    previous_force = @force
    @force = force || @force
    Rails.cache.fetch(self.class.cache_key(@owner_id, panel), expires_in: interval.seconds, race_condition_ttl: 5.seconds, force: @force) do
      @original_file_totals = nil
      remove_instance_variable(:@variant_sample) if instance_variable_defined?(:@variant_sample)
      { data: public_send(panel), generated_at: Time.current }
    end
  ensure
    @force = previous_force
  end

  def library
    {
      originals: original_file_totals,
      checksums: Photo.group(:checksum_status).count,
      drive_archives: DriveArchiveObject.group(:status).count
    }
  end

  def maintenance
    library_data = fetch("library").fetch(:data)
    @original_file_totals = library_data.fetch(:originals)
    library_data.merge(storage: storage_status, derivatives: derivative_totals, location_status: location_status)
  end

  def health
    stale_sql = FileHealthCheck.sanitize_sql_array([ "COUNT(*) FILTER (WHERE checked_at < ?)", OriginalFileHealthPatrolJob::DEFAULT_STALE_AFTER.ago ])
    grouped = latest_checks.group(:status).pluck(:status, Arel.sql("COUNT(*)"), Arel.sql(stale_sql))
    status_counts = grouped.to_h { |status, count, _stale| [ status, count ] }
    checked = status_counts.values.sum
    original_count = original_photos.count
    queue_data = fetch("queues").fetch(:data)
    jobs = QueueStatusSnapshot::EXECUTION_STATES.keys.index_with(0).merge(total: 0)
    queue_data.fetch(:job_classes).each do |row|
      next unless HEALTH_JOB_CLASSES.include?(row.fetch(:name))

      row.fetch(:counts).each { |state, count| jobs[state] += count }
      jobs[:total] += row.fetch(:total)
    end
    {
      health: {
        checked: checked, unchecked: [ original_count - checked, 0 ].max,
        checked_percent: original_count.positive? ? (checked.to_f / original_count * 100).round(1) : 100.0,
        attention: FileHealthCheck::ATTENTION_STATUSES.sum { |status| status_counts.fetch(status, 0) },
        stale: grouped.sum { |_status, _count, stale| stale },
        status_counts: status_counts, jobs: jobs
      },
      health_timeline: health_timeline,
      last_health_check_at: FileHealthCheck.maximum(:checked_at),
      recent_checks: check_rows(latest_checks),
      recent_attention: check_rows(latest_checks.needs_attention)
    }
  end

  def analysis
    { analysis_status: analysis_status }
  end

  def queues
    snapshot = QueueStatusSnapshot.build
    available = snapshot.available?
    rows = snapshot.queues
    pauses = snapshot.pauses
    paused_names = pauses.map { |pause| pause.fetch("queue_name") }
    rows_by_name = rows.index_by { |row| row.fetch(:name) }
    managed = (MANAGED_QUEUE_NAMES + rows_by_name.keys + paused_names).uniq.map do |name|
      counts = rows_by_name[name]&.fetch(:counts) || QueueStatusSnapshot::EXECUTION_STATES.keys.index_with(0)
      { name: name, paused: paused_names.include?(name), ready: counts[:ready], claimed: counts[:claimed],
        total: counts.values.sum, counts: counts, managed: MANAGED_QUEUE_NAMES.include?(name) }
    end
    {
      snapshot_available: available, queue_totals: snapshot.totals, queues: rows,
      job_classes: snapshot.job_classes, recent_failures: snapshot.recent_failures,
      processes: snapshot.processes, pauses: pauses, finished_counts: snapshot.finished_counts,
      pruned_failure_count: available ? snapshot.pruned_failure_count : 0,
      controls: { queues: managed }
    }
  end

  def activity
    {
      repository_events: RepositoryEvent.latest_first.limit(25).map(&:attributes),
      unread_repository_events: RepositoryEvent.unread.count
    }
  end

  private

  def original_photos
    Photo.joins(:original_attachment)
  end

  def original_file_totals
    @original_file_totals ||= begin
      columns = [
        "COUNT(*)", "COUNT(*) FILTER (WHERE photos.content_type LIKE 'image/%')",
        "COUNT(*) FILTER (WHERE photos.content_type LIKE 'video/%')",
        "COUNT(*) FILTER (WHERE photos.visibility = 'public' AND NOT photos.restricted AND photos.archived_at IS NULL)",
        "COUNT(*) FILTER (WHERE photos.visibility = 'private' AND NOT photos.restricted AND photos.archived_at IS NULL)",
        "COUNT(*) FILTER (WHERE photos.restricted)", "COUNT(*) FILTER (WHERE photos.archived_at IS NOT NULL)"
      ]
      counts = original_photos.pick(*columns.map { |sql| Arel.sql(sql) })
      %i[total images videos public private restricted archived].zip(counts).to_h.merge(
        bytes: ActiveStorage::Blob.joins(:attachments).where(active_storage_attachments: { record_type: "Photo", name: "original" }).sum(:byte_size)
      )
    end
  end

  def latest_checks
    # Ignore old checks whose original has since been detached from the library.
    ids = FileHealthCheck.select("DISTINCT ON (photo_id) id").order("photo_id, checked_at DESC, id DESC")
    FileHealthCheck.where(id: ids, photo_id: original_photos.select(:id))
  end

  def check_rows(scope)
    scope.joins(:photo).select("file_health_checks.*", "photos.original_filename AS photo_filename").latest_first.limit(25).map(&:attributes)
  end

  def health_timeline
    now = Time.current
    buckets = 24.downto(0).map { |hours| hours.hours.ago(now).in_time_zone.beginning_of_hour }.uniq.sort.index_with { Hash.new(0) }
    # Group in PostgreSQL instead of transferring every check in the last day to Ruby.
    hourly = FileHealthCheck.where(checked_at: (now - 24.hours)..now)
      .group(Arel.sql("FLOOR(EXTRACT(EPOCH FROM checked_at) / 3600)"), :status).count
    hourly.each do |(epoch_hour, status), count|
      time = Time.at(epoch_hour.to_i * 3600).in_time_zone.beginning_of_hour
      buckets[time][status] += count if buckets.key?(time)
    end
    buckets.map do |time, counts|
      { label: time.strftime("%-I%P"), healthy: counts.fetch("ok", 0) + counts.fetch("healed", 0),
        attention: FileHealthCheck::ATTENTION_STATUSES.sum { |status| counts.fetch(status, 0) } }
    end
  end

  def run_counts(scope)
    PhotoAnalysisRun::STATUSES.index_with(0).merge(scope.group(:status).count)
  end

  def analysis_errors(provider)
    PhotoAnalysisRun.where(provider: provider).where.not(error: [ nil, "" ]).latest_first.limit(5)
      .select(:id, :photo_id, :error, :created_at).map(&:attributes)
  end

  def variant_sample
    return @variant_sample if defined?(@variant_sample)

    @variant_sample = original_photos.where("photos.content_type LIKE ?", "image/%").includes(original_attachment: :blob).first
  end

  def derivative_totals
    image_total = original_file_totals.fetch(:images)
    video_total = original_file_totals.fetch(:videos)
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
    sample = variant_sample
    return unless sample&.original&.attached? && sample.original.variable?

    sample.original.variant(variant_name).variation.digest
  rescue ActiveStorage::InvariableError
    nil
  end

  def location_status
    total, matched_count = geotagged_photos.pick(Arel.sql("COUNT(*)"), Arel.sql("COUNT(photo_metadata.photo_place_id)"))

    {
      buckets: total,
      named: matched_count,
      missing: total - matched_count,
      geocoder_configured: LocationReverseGeocoder.api_key.present?
    }
  end

  def geotagged_photos
    Photo
      .where(restricted: false, archived_at: nil)
      .joins(:metadata)
      .merge(PhotoMetadata.geotagged)
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
        run_counts: run_counts(run_scope),
        latest_errors: analysis_errors("openclip")
      },
      openrouter: openrouter_analysis_status
    }
  end

  def openrouter_analysis_status
    model = ENV.fetch("OPENROUTER_VISION_MODEL", OpenrouterVisionClient::DEFAULT_MODEL)
    eligible_photos = original_photos.where(restricted: false).where("photos.content_type LIKE ?", "image/%")
    eligible = eligible_photos.distinct.count
    runs = PhotoAnalysisRun.where(
      provider: "openrouter",
      model: model,
      model_version: PhotoAnalysisOpenrouterJob::PROMPT_VERSION
    )
    completed = runs.complete.where(photo_id: eligible_photos.select(:id)).select(:photo_id).distinct.count
    spend = PhotoAnalysisRun.openrouter_spend.to_d
    costed = PhotoAnalysisRun.where(provider: "openrouter", status: "complete").where.not(cost_usd: nil)
    average_cost = costed.average(:cost_usd).to_d
    budget = ENV.fetch("OPENROUTER_BUDGET_USD", 100).to_d
    missing = [ eligible - completed, 0 ].max

    {
      model:,
      prompt_version: PhotoAnalysisOpenrouterJob::PROMPT_VERSION,
      configured: ENV["OPENROUTER_API_KEY"].present?,
      eligible:,
      completed:,
      missing:,
      coverage_percent: eligible.positive? ? (completed.to_f / eligible * 100).round(1) : 100.0,
      run_counts: run_counts(runs),
      spend:,
      budget:,
      average_cost:,
      projected_remaining_cost: average_cost.positive? ? average_cost * missing : PhotoAnalysisOpenrouterBackfill::DEFAULT_ESTIMATED_COST_USD * missing,
      latest_errors: analysis_errors("openrouter")
    }
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
      path_attention: path_attention
    }
  end

  def configured_path_exists_in_container(configured_path, service_root)
    return nil if configured_path.blank?
    return File.directory?(configured_path) if configured_path == service_root

    nil
  end
end
