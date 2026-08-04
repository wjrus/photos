class PhotoAnalysisOpenrouterBackfill
  DEFAULT_LIMIT = 100
  MAX_LIMIT = 50_000
  DEFAULT_ESTIMATED_COST_USD = BigDecimal("0.0025")

  Result = Data.define(
    :eligible,
    :requested,
    :queued,
    :spend,
    :budget,
    :estimated_cost,
    :dry_run
  ) do
    def remaining_budget
      [ budget - spend, 0.to_d ].max
    end
  end

  def initialize(output: nil)
    @output = output
  end

  def enqueue(limit: DEFAULT_LIMIT, dry_run: false)
    raise ArgumentError, "OpenRouter analysis is disabled in Repository Status" unless enabled?
    raise ArgumentError, "OPENROUTER_API_KEY is not configured" if ENV["OPENROUTER_API_KEY"].blank?

    requested = Integer(limit).clamp(1, MAX_LIMIT)
    scope = eligible_photos
    eligible = scope.count
    allowed = jobs_allowed_by_budget
    photos = scope.limit([ requested, allowed ].min)
    queued = 0

    log "OpenRouter backfill: eligible=#{eligible} requested=#{requested} budget_allows=#{allowed}"
    unless dry_run
      photos.each do |photo|
        queued += 1 if reserve_and_enqueue(photo)
        log "Queued #{queued} photos..." if (queued % 100).zero?
      end
    end

    queued = [ eligible, requested, allowed ].min if dry_run
    Result.new(
      eligible:,
      requested:,
      queued:,
      spend: current_spend,
      budget: budget,
      estimated_cost: estimated_cost,
      dry_run:
    )
  end

  def eligible_photos
    Photo
      .joins(:original_attachment)
      .where(restricted: false)
      .where("photos.content_type LIKE ?", "image/%")
      .where.not(id: current_or_reserved_photo_ids)
      .reorder(Arel.sql("photos.captured_at DESC NULLS LAST, photos.created_at DESC, photos.id DESC"))
  end

  private

  def enabled?
    AppSetting.boolean(AppSetting::ANALYSIS_OPENROUTER_ENABLED, default: false)
  end

  def model
    ENV.fetch("OPENROUTER_VISION_MODEL", OpenrouterVisionClient::DEFAULT_MODEL)
  end

  def current_or_reserved_photo_ids
    PhotoAnalysisRun.where(
      provider: "openrouter",
      model: model,
      model_version: PhotoAnalysisOpenrouterJob::PROMPT_VERSION,
      status: %w[pending running complete]
    ).select(:photo_id)
  end

  def current_spend
    PhotoAnalysisRun.openrouter_spend.to_d
  end

  def budget
    ENV.fetch("OPENROUTER_BUDGET_USD", 100).to_d
  end

  def estimated_cost
    ENV.fetch("OPENROUTER_ESTIMATED_COST_USD", DEFAULT_ESTIMATED_COST_USD).to_d
  end

  def jobs_allowed_by_budget
    return MAX_LIMIT unless budget.positive?
    return 0 unless estimated_cost.positive?

    ((budget - current_spend) / estimated_cost).floor.clamp(0, MAX_LIMIT)
  end

  def reserve_and_enqueue(photo)
    run = photo.with_lock do
      next if current_or_reserved_photo_ids.where(photo_id: photo.id).exists?

      photo.analysis_runs.create!(
        provider: "openrouter",
        model: model,
        model_version: PhotoAnalysisOpenrouterJob::PROMPT_VERSION,
        status: "pending",
        source_variant: "display",
        raw: { queued_by: "backfill", queued_at: Time.current.iso8601 }
      )
    end
    return false unless run

    PhotoAnalysisOpenrouterJob.perform_later(photo)
    true
  rescue StandardError => error
    run&.update!(status: "failed", finished_at: Time.current, error: "Enqueue failed: #{error.message}")
    raise
  end

  def log(message)
    @output&.puts(message)
  end
end
