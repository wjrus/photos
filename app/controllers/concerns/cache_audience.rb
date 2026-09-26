module CacheAudience
  extend ActiveSupport::Concern

  private

  def cache_owner_aggregate(key, **options, &block)
    # Viewer grants and revocations span several associations. Recheck their
    # visible scope on every request instead of serving cached private metadata.
    return yield unless current_user&.owner?

    Rails.cache.fetch(key, **options, &block)
  end

  def cache_audience_key
    if current_user&.owner?
      "owner/#{current_user.id}"
    elsif current_user
      "viewer/#{current_user.id}"
    else
      "anonymous"
    end
  end
end
