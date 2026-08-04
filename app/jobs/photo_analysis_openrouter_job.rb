require "digest"

class PhotoAnalysisOpenrouterJob < ApplicationJob
  queue_as :vision

  PROMPT_VERSION = "caption-v1".freeze
  ACTIVE_RUN_WINDOW = 15.minutes

  retry_on OpenrouterVisionClient::RetryableError, wait: :polynomially_longer, attempts: 5

  def perform(photo)
    return unless enabled?
    return if photo.restricted? || !photo.image? || !photo.original.attached?

    source = analysis_source(photo)
    image_bytes = source.fetch(:blob).download
    source_checksum = Digest::SHA256.hexdigest(image_bytes)
    return if current_run_exists?(photo, source_checksum)
    return if budget_exhausted?

    run = create_run(photo, source:, source_checksum:)
    return unless run

    response = vision_client.analyze(image_bytes:, content_type: source.fetch(:blob).content_type || "image/jpeg")
    persist_result(photo, run, response)
  rescue OpenrouterVisionClient::Error, ActiveStorage::FileNotFoundError => error
    run&.update!(status: "failed", finished_at: Time.current, error: error.message)
    raise
  rescue StandardError => error
    run&.update!(status: "failed", finished_at: Time.current, error: "#{error.class}: #{error.message}")
    raise
  end

  private

  def enabled?
    AppSetting.boolean(AppSetting::ANALYSIS_OPENROUTER_ENABLED, default: false)
  end

  def vision_client
    OpenrouterVisionClient.new
  end

  def model
    ENV.fetch("OPENROUTER_VISION_MODEL", OpenrouterVisionClient::DEFAULT_MODEL)
  end

  def budget_exhausted?
    budget = ENV.fetch("OPENROUTER_BUDGET_USD", 100).to_d
    return false unless budget.positive?

    PhotoAnalysisRun.openrouter_spend >= budget
  end

  def create_run(photo, source:, source_checksum:)
    photo.with_lock do
      return if current_run_exists?(photo, source_checksum)
      return if active_run_exists?(photo, source_checksum)

      pending_run = photo.analysis_runs.where(
        provider: "openrouter",
        model: model,
        model_version: PROMPT_VERSION,
        status: "pending"
      ).latest_first.first

      attributes = {
        status: "running",
        started_at: Time.current,
        source_variant: source.fetch(:variant),
        source_checksum_sha256: source_checksum
      }
      return pending_run.tap { |run| run.update!(attributes) } if pending_run

      photo.analysis_runs.create!(
        provider: "openrouter",
        model: model,
        model_version: PROMPT_VERSION,
        raw: { privacy: { zdr: true, data_collection: "deny" } },
        **attributes
      )
    end
  end

  def current_run_exists?(photo, source_checksum)
    photo.analysis_runs.exists?(
      provider: "openrouter",
      model: model,
      model_version: PROMPT_VERSION,
      source_checksum_sha256: source_checksum,
      status: "complete"
    )
  end

  def active_run_exists?(photo, source_checksum)
    photo.analysis_runs.where(
      provider: "openrouter",
      model: model,
      model_version: PROMPT_VERSION,
      source_checksum_sha256: source_checksum,
      status: %w[pending running]
    ).where("started_at >= ?", ACTIVE_RUN_WINDOW.ago).exists?
  end

  def analysis_source(photo)
    display = photo.processed_original_variant_record(:display)
    return { blob: display.image.blob, variant: "display" } if display&.image&.attached?

    photo.original.variant(:display).processed if photo.original.variable?
    display = photo.reload.processed_original_variant_record(:display)
    return { blob: display.image.blob, variant: "display" } if display&.image&.attached?

    raise OpenrouterVisionClient::Error, "OpenRouter analysis requires the display JPEG derivative"
  rescue ActiveStorage::InvariableError, ActiveStorage::UnrepresentableError => error
    raise OpenrouterVisionClient::Error, "OpenRouter could not prepare the display JPEG derivative: #{error.message}"
  end

  def persist_result(photo, run, response)
    PhotoAnalysisRun.transaction do
      run.update!(
        status: "complete",
        model: response.fetch("model"),
        summary: response.fetch("caption"),
        request_id: response["request_id"],
        input_tokens: response["input_tokens"],
        output_tokens: response["output_tokens"],
        cost_usd: response["cost"],
        finished_at: Time.current,
        raw: response.fetch("raw").merge(
          "normalized" => response.slice("caption", "tags", "readable_text", "provider")
        )
      )

      photo.analysis_tags.where(provider: "openrouter").delete_all
      response.fetch("tags").each do |tag|
        photo.analysis_tags.create!(
          photo_analysis_run: run,
          provider: "openrouter",
          name: tag,
          category: "visual",
          raw: { source: "openrouter", model: response.fetch("model") }
        )
      end

      Photo.where(id: photo.id).where(description: [ nil, "" ]).update_all(
        description: response.fetch("caption"),
        updated_at: Time.current
      )
    end
  end
end
