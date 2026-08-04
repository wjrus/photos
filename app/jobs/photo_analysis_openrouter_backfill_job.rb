class PhotoAnalysisOpenrouterBackfillJob < ApplicationJob
  queue_as :vision

  def perform(limit: PhotoAnalysisOpenrouterBackfill::DEFAULT_LIMIT)
    result = PhotoAnalysisOpenrouterBackfill.new.enqueue(limit:)
    Rails.logger.info(
      "OpenRouter vision backfill reserved=#{result.queued} eligible=#{result.eligible} " \
      "requested=#{result.requested} spent=#{result.spend} budget=#{result.budget}"
    )
  end
end
