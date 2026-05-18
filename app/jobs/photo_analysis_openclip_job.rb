class PhotoAnalysisOpenclipJob < ApplicationJob
  queue_as :analysis

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

    response = local_client.openclip_embed(
      photo_id: photo.id,
      image_path: analysis_image_path(photo),
      source_variant: run.source_variant
    )

    photo.embeddings.create!(
      photo_analysis_run: run,
      provider: "openclip",
      model: response.fetch("model"),
      model_version: response["model_version"],
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
  rescue PhotoAnalysisLocalClient::Error, ActiveStorage::FileNotFoundError, Errno::ENOENT => error
    run&.update!(status: "failed", finished_at: Time.current, error: error.message)
    raise
  end

  private

  def local_client
    PhotoAnalysisLocalClient.new
  end

  def analysis_image_path(photo)
    blob = analysis_blob(photo)
    raise "Local OpenCLIP analysis requires disk-backed Active Storage" unless blob.service.respond_to?(:path_for)

    blob.service.path_for(blob.key)
  end

  def analysis_blob(photo)
    display = photo.processed_original_variant_record(:display)
    return display.image.blob if display&.image&.attached?

    photo.original.blob
  end
end
