class GenerateVideoPreviewJob < ApplicationJob
  queue_as :video_previews

  def perform(photo)
    GeneratePhotoDerivativesJob.perform_now(photo, preview_only: true)
  end
end
