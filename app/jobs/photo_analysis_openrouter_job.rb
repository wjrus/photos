require "digest"

class PhotoAnalysisOpenrouterJob < ApplicationJob
  queue_as :vision

  PROMPT_VERSION = "caption-v1".freeze
  ACTIVE_RUN_WINDOW = 15.minutes
  MAX_RETRY_ATTEMPTS = 5

  rescue_from OpenrouterVisionClient::RetryableError do |error|
    if executions < MAX_RETRY_ATTEMPTS
      wait = error.retry_after || (executions**4 + 2)
      Rails.logger.warn("OpenRouter vision retrying in #{wait}s after attempt #{executions}: #{error.message}")
      retry_job wait:, error:
    else
      raise error
    end
  end

  def perform(photo, force: false)
    return unless enabled?
    return if photo.restricted? || !photo.image? || !photo.original.attached?

    source = analysis_source(photo)
    image_bytes = source.fetch(:blob).download
    source_checksum = Digest::SHA256.hexdigest(image_bytes)
    context = analysis_context(photo)
    return if !force && current_run_exists?(photo, source_checksum)
    if budget_exhausted?
      Rails.logger.warn("OpenRouter vision skipped photo=#{photo.id}: budget exhausted")
      return
    end

    run = create_run(photo, source:, source_checksum:, context:, force:)
    return unless run

    Rails.logger.info(
      "OpenRouter vision started photo=#{photo.id} run=#{run.id} model=#{run.model} " \
      "source=#{run.source_variant} bytes=#{image_bytes.bytesize} context=#{context.keys.join(',').presence || 'none'}"
    )
    response = vision_client.analyze(
      image_bytes:,
      content_type: source.fetch(:blob).content_type || "image/jpeg",
      context:
    )
    persist_result(photo, run, response)
  rescue OpenrouterVisionClient::Error, ActiveStorage::FileNotFoundError => error
    record_failure(run, error)
    diagnostics = error.respond_to?(:details) ? error.details : {}
    Rails.logger.warn(
      "OpenRouter vision failed photo=#{photo.id} run=#{run&.id || 'none'}: #{error.message} " \
      "diagnostics=#{diagnostics.to_json}"
    )
    raise
  rescue StandardError => error
    run&.update!(status: "failed", finished_at: Time.current, error: "#{error.class}: #{error.message}")
    Rails.logger.error("OpenRouter vision failed photo=#{photo.id} run=#{run&.id || 'none'}: #{error.class}: #{error.message}")
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

  def create_run(photo, source:, source_checksum:, context:, force:)
    photo.with_lock do
      return if !force && current_run_exists?(photo, source_checksum)
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
      if pending_run
        pending_raw = pending_run.raw.merge(
          "privacy" => { "zdr" => true, "data_collection" => "deny" },
          "input_context" => context.stringify_keys
        )
        return pending_run.tap { |run| run.update!(attributes.merge(raw: pending_raw)) }
      end

      photo.analysis_runs.create!(
        provider: "openrouter",
        model: model,
        model_version: PROMPT_VERSION,
        raw: {
          privacy: { zdr: true, data_collection: "deny" },
          input_context: context
        },
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

  def analysis_context(photo)
    metadata = photo.metadata
    captured_at = metadata&.captured_at || photo.captured_at
    context = {}
    context[:capture_date] = captured_at.to_date.iso8601 if captured_at

    if metadata&.location?
      location_id = PhotoLocation.id_for_coordinates(metadata.latitude, metadata.longitude)
      place = PhotoLocationPlace.find_by(location_id: location_id)
      location_name = approximate_location_name(place)
      context[:approximate_location] = location_name if location_name
    end

    camera = [ metadata&.camera_make, metadata&.camera_model ].compact_blank.join(" ").presence
    context[:camera] = camera if camera
    context
  end

  def approximate_location_name(place)
    return unless place && !place.plus_code_name?

    components = place.raw.fetch("address_components", [])
    locality = component_name(components, %w[locality postal_town administrative_area_level_3 administrative_area_level_2])
    region = component_name(components, %w[administrative_area_level_1])
    country = component_name(components, %w[country])
    [ locality, region, country ].compact_blank.uniq.join(", ").presence || place.name
  end

  def component_name(components, preferred_types)
    preferred_types.each do |type|
      name = components.find { |component| Array(component["types"]).include?(type) }&.fetch("long_name", nil)
      return name if name.present?
    end
    nil
  end

  def persist_result(photo, run, response)
    input_context = run.raw.fetch("input_context", {})
    previous_generated_caption = photo.analysis_runs
      .where(provider: "openrouter", status: "complete")
      .where.not(id: run.id)
      .latest_first
      .pick(:summary)
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
          "normalized" => response.slice("caption", "tags", "readable_text", "provider"),
          "input_context" => input_context,
          "privacy" => { "zdr" => true, "data_collection" => "deny" }
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

      replaceable_captions = [ nil, "", previous_generated_caption ].uniq
      Photo.where(id: photo.id).where(description: replaceable_captions).update_all(
        description: response.fetch("caption"),
        updated_at: Time.current
      )

      photo.analysis_runs.where(
        provider: "openrouter",
        model: run.model,
        model_version: run.model_version,
        source_checksum_sha256: run.source_checksum_sha256,
        status: "failed"
      ).where.not(id: run.id).find_each do |failed_run|
        failed_run.update!(status: "skipped", error: "Recovered after retry: #{failed_run.error}")
      end
    end

    Rails.logger.info(
      "OpenRouter vision completed photo=#{photo.id} run=#{run.id} provider=#{response['provider'].presence || 'unknown'} " \
      "input_tokens=#{response['input_tokens'] || 'unknown'} output_tokens=#{response['output_tokens'] || 'unknown'} " \
      "cost=#{response['cost'] || 'unknown'} tags=#{response.fetch('tags').size} " \
      "readable_text=#{response.fetch('readable_text').size}"
    )
  end

  def record_failure(run, error)
    return unless run

    details = error.respond_to?(:details) ? error.details.stringify_keys : {}
    usage = details.fetch("usage", {}).to_h
    run.update!(
      status: "failed",
      request_id: details["request_id"],
      model: details["model"].presence || run.model,
      input_tokens: usage["prompt_tokens"],
      output_tokens: usage["completion_tokens"],
      cost_usd: usage["cost"],
      finished_at: Time.current,
      error: error.message,
      raw: run.raw.merge("failure_response" => details)
    )
  end
end
