class PhotoAnalysisOpenclipJob < ApplicationJob
  queue_as :analysis

  UnsupportedSourceError = Class.new(StandardError)

  def perform(photo)
    return unless AppSetting.boolean(AppSetting::ANALYSIS_OPENCLIP_ENABLED, default: false)

    run = photo.analysis_runs.create!(
      provider: "openclip",
      model: ENV.fetch("OPENCLIP_MODEL", "ViT-B-32"),
      model_version: ENV.fetch("OPENCLIP_PRETRAINED", "laion2b_s34b_b79k"),
      status: "running",
      started_at: Time.current,
      source_variant: "display",
      raw: { local_container_url: ENV.fetch("ANALYSIS_LOCAL_CONTAINER_URL", "http://analysis-local:8000") }
    )
    source = analysis_source(photo)
    run.update!(source_variant: source.fetch(:variant)) if run.source_variant != source.fetch(:variant)

    response = local_client.openclip_embed(
      photo_id: photo.id,
      image_path: analysis_image_path(source.fetch(:blob)),
      source_variant: run.source_variant
    )

    embedding = photo.embeddings.find_or_initialize_by(
      provider: "openclip",
      model: response.fetch("model"),
      model_version: response["model_version"]
    )
    embedding.update!(
      photo_analysis_run: run,
      dimensions: response.fetch("dimensions"),
      source_variant: run.source_variant,
      index_key: response.fetch("index_key"),
      embedded_at: Time.current,
      raw: response
    )
    run.update!(
      status: "complete",
      model: response.fetch("model"),
      model_version: response["model_version"],
      finished_at: Time.current,
      raw: response
    )
  rescue UnsupportedSourceError => error
    run&.update!(status: "skipped", finished_at: Time.current, error: error.message)
  rescue PhotoAnalysisLocalClient::Error, ActiveStorage::FileNotFoundError, Errno::ENOENT => error
    run&.update!(status: "failed", finished_at: Time.current, error: error.message)
    raise
  end

  private

  def local_client
    PhotoAnalysisLocalClient.new
  end

  def analysis_image_path(blob)
    raise "Local OpenCLIP analysis requires disk-backed Active Storage" unless blob.service.respond_to?(:path_for)

    blob.service.path_for(blob.key)
  end

  def analysis_source(photo)
    return video_preview_source(photo) if photo.video?
    return display_image_source(photo) if photo.image?

    raise UnsupportedSourceError, "OpenCLIP analysis requires an image display derivative or video preview frame."
  end

  def display_image_source(photo)
    display = photo.processed_original_variant_record(:display)
    return { blob: display.image.blob, variant: "display" } if display&.image&.attached?

    begin
      photo.original.variant(:display).processed if photo.original.variable?
      display = photo.reload.processed_original_variant_record(:display)
    rescue StandardError => error
      raise UnsupportedSourceError, "OpenCLIP could not prepare the display JPEG derivative: #{error.class}: #{error.message}"
    end

    return { blob: display.image.blob, variant: "display" } if display&.image&.attached?

    raise UnsupportedSourceError, "OpenCLIP analysis requires the display JPEG derivative."
  end

  def video_preview_source(photo)
    raise UnsupportedSourceError, "OpenCLIP analysis requires a video preview frame. Run video preview generation before analysis." unless photo.video_preview.attached?

    { blob: photo.video_preview.blob, variant: "video_preview" }
  end
end
