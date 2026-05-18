class PhotoAnalysisBackfillJob < ApplicationJob
  queue_as :analysis

  DEFAULT_BATCH_SIZE = 100
  MAX_BATCH_SIZE = 10_000

  def perform(providers: enabled_providers, batch_size: DEFAULT_BATCH_SIZE)
    providers = Array(providers).map(&:to_s) & PhotoAnalysisRun::PROVIDERS
    return if providers.empty?

    providers.each do |provider|
      due_photos(provider: provider, batch_size: batch_size).each do |photo|
        PhotoAnalysisOpenclipJob.perform_later(photo) if provider == "openclip"
        PhotoAnalysisYoloJob.perform_later(photo) if provider == "yolo"
      end
    end
  end

  private

  def enabled_providers
    providers = []
    providers << "openclip" if AppSetting.boolean(AppSetting::ANALYSIS_OPENCLIP_ENABLED, default: false)
    providers << "yolo" if AppSetting.boolean(AppSetting::ANALYSIS_YOLO_ENABLED, default: false)
    providers
  end

  def due_photos(provider:, batch_size:)
    scope = Photo
      .joins(:original_attachment)
      .where(restricted: false)
      .reorder(Arel.sql("photos.captured_at DESC NULLS LAST, photos.created_at DESC, photos.id DESC"))

    scope = without_current_openclip_embedding(scope) if provider == "openclip"

    scope.limit(Integer(batch_size).clamp(1, MAX_BATCH_SIZE))
  end

  def without_current_openclip_embedding(scope)
    scope.where.not(
      id: PhotoEmbedding
        .where(
          provider: "openclip",
          model: openclip_model,
          model_version: openclip_model_version
        )
        .select(:photo_id)
    )
  end

  def openclip_model
    ENV.fetch("OPENCLIP_MODEL", "ViT-B-32")
  end

  def openclip_model_version
    ENV.fetch("OPENCLIP_PRETRAINED", "laion2b_s34b_b79k")
  end
end
