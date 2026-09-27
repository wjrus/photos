class RepositoryStatusController < ApplicationController
  MANAGED_QUEUE_NAMES = RepositoryStatusData::MANAGED_QUEUE_NAMES
  SECTION_PANELS = {
    "overview" => %w[library queues activity], "files" => %w[health maintenance],
    "analysis" => %w[analysis], "queues" => %w[queues]
  }.freeze
  SECTION_ALIASES = { "maintenance" => "files", "health" => "files", "activity" => "overview" }.freeze

  owner_access_message "Only the owner can see repository status."
  before_action :prevent_status_caching
  before_action :require_owner!

  def show
    @status_section = status_section
    load_settings if @status_section.in?(%w[files analysis])
    return unless params[:synchronous] == "1"

    source = RepositoryStatusData.new(owner_id: current_user.id)
    @panel_data = SECTION_PANELS.fetch(@status_section).to_h { |panel| [ panel, source.fetch(panel).fetch(:data) ] }
  end

  def panel
    name = params[:panel].to_s
    return render json: { error: "Unknown status panel." }, status: :not_found unless RepositoryStatusData::INTERVALS.key?(name)

    snapshot = RepositoryStatusData.new(owner_id: current_user.id).fetch(name, force: params[:refresh] == "1")
    partial = name == "queues" && params[:variant] == "summary" ? "queues_summary" : name
    render json: {
      html: render_to_string(partial: "repository_status/panels/#{partial}", formats: [ :html ], locals: { data: snapshot.fetch(:data) }),
      generated_at: snapshot.fetch(:generated_at).iso8601,
      version: Digest::SHA256.hexdigest(snapshot.fetch(:data).to_json),
      refresh_after: RepositoryStatusData::INTERVALS.fetch(name)
    }
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
    when "openrouter_analysis"
      if !AppSetting.boolean(AppSetting::ANALYSIS_OPENROUTER_ENABLED, default: false)
        redirect_to repository_status_redirect_path, alert: "Enable OpenRouter vision first."
      elsif ENV["OPENROUTER_API_KEY"].blank?
        redirect_to repository_status_redirect_path, alert: "OPENROUTER_API_KEY is not configured."
      else
        PhotoAnalysisOpenrouterBackfillJob.perform_later(limit: openrouter_batch_size)
        redirect_to repository_status_redirect_path, notice: "OpenRouter vision backfill queued."
      end
    when "geocode_locations"
      GeocodeMissingPhotoLocationsJob.perform_later(limit: geocode_location_limit)
      redirect_to repository_status_redirect_path, notice: "Location name geocoding queued."
    else
      OriginalFileHealthPatrolJob.perform_later(batch_size: patrol_batch_size)
      redirect_to repository_status_redirect_path, notice: "Repository patrol queued."
    end
    expire_status_panels
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
    expire_status_panels
  end

  private

  def prevent_status_caching
    response.headers["Cache-Control"] = "private, no-store"
  end

  def status_section
    requested = params[:section].to_s
    SECTION_ALIASES[requested] || requested.presence_in(SECTION_PANELS.keys) || "overview"
  end

  def repository_status_redirect_path
    section = status_section
    section == "overview" ? repository_status_path : repository_status_path(section: section)
  end

  def load_settings
    defaults = AppSetting::ANALYSIS_BOOLEAN_SETTINGS.merge(AppSetting::ORIGINAL_FILE_AUTO_HEAL => false)
    saved = AppSetting.where(key: defaults.keys).pluck(:key, :value).to_h
    @settings = defaults.merge(saved.transform_values { |value| ActiveModel::Type::Boolean.new.cast(value) })
    @setting_sources = defaults.keys.to_h { |key| [ key, saved.key?(key) ? "repository setting" : "app default" ] }
  end

  def expire_status_panels
    panels = case params[:control]
    when "repository_events" then %w[activity]
    when "analysis" then %w[analysis]
    when "original_file_auto_heal" then %w[maintenance]
    else %w[queues health analysis maintenance]
    end
    RepositoryStatusData.invalidate(current_user.id, *panels)
  end

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

  def analysis_batch_size
    Integer(params[:batch_size].presence || ENV.fetch("ANALYSIS_BACKFILL_BATCH_SIZE", PhotoAnalysisBackfillJob::DEFAULT_BATCH_SIZE)).clamp(1, PhotoAnalysisBackfillJob::MAX_BATCH_SIZE)
  rescue ArgumentError
    PhotoAnalysisBackfillJob::DEFAULT_BATCH_SIZE
  end

  def openrouter_batch_size
    Integer(params[:batch_size].presence || PhotoAnalysisOpenrouterBackfill::DEFAULT_LIMIT).clamp(1, PhotoAnalysisOpenrouterBackfill::MAX_LIMIT)
  rescue ArgumentError
    PhotoAnalysisOpenrouterBackfill::DEFAULT_LIMIT
  end

  def geocode_location_limit
    Integer(params[:limit].presence || GeocodeMissingPhotoLocationsJob::DEFAULT_LIMIT).clamp(1, GeocodeMissingPhotoLocationsJob::MAX_LIMIT)
  rescue ArgumentError
    GeocodeMissingPhotoLocationsJob::DEFAULT_LIMIT
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

  def analysis_control_label(key)
    {
      AppSetting::ANALYSIS_OPENCLIP_ENABLED => "OpenCLIP semantic search",
      AppSetting::ANALYSIS_YOLO_ENABLED => "YOLO object detection",
      AppSetting::ANALYSIS_OPENAI_ENABLED => "OpenAI vision enrichment",
      AppSetting::ANALYSIS_OPENAI_PUBLIC_ONLY => "OpenAI public photos only",
      AppSetting::ANALYSIS_OPENAI_REQUIRE_OWNER_CONFIRM => "OpenAI requires owner confirmation",
      AppSetting::ANALYSIS_OPENROUTER_ENABLED => "OpenRouter Qwen vision captions",
      AppSetting::ANALYSIS_OPENROUTER_AUTO_NEW_ENABLED => "OpenRouter captions for new uploads"
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
