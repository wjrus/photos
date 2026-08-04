class PhotoAnalysisOpenrouterBackfillJob < ApplicationJob
  queue_as :vision

  def perform(limit: PhotoAnalysisOpenrouterBackfill::DEFAULT_LIMIT)
    PhotoAnalysisOpenrouterBackfill.new.enqueue(limit:)
  end
end
