class PhotoAnalysisBackfillJob < ApplicationJob
  queue_as :analysis

  DEFAULT_BATCH_SIZE = 100

  def perform(providers: enabled_providers, batch_size: DEFAULT_BATCH_SIZE)
    providers = Array(providers).map(&:to_s) & PhotoAnalysisRun::PROVIDERS
    return if providers.empty?

    due_photos(batch_size: batch_size).each do |photo|
      PhotoAnalysisOpenclipJob.perform_later(photo) if providers.include?("openclip")
      PhotoAnalysisYoloJob.perform_later(photo) if providers.include?("yolo")
    end
  end

  private

  def enabled_providers
    providers = []
    providers << "openclip" if AppSetting.boolean(AppSetting::ANALYSIS_OPENCLIP_ENABLED, default: false)
    providers << "yolo" if AppSetting.boolean(AppSetting::ANALYSIS_YOLO_ENABLED, default: false)
    providers
  end

  def due_photos(batch_size:)
    Photo
      .joins(:original_attachment)
      .where(restricted: false)
      .reorder(Arel.sql("photos.captured_at DESC NULLS LAST, photos.created_at DESC, photos.id DESC"))
      .limit(Integer(batch_size).clamp(1, 1_000))
  end
end
