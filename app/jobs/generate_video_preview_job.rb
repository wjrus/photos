class GenerateVideoPreviewJob < ApplicationJob
  queue_as :video_previews

  def perform(photo)
    Rails.logger.info("Generating queued video preview for photo #{photo.id}")
    GeneratePhotoDerivativesJob.perform_now(photo, preview_only: true)
  end
end
