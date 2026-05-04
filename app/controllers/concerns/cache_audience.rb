module CacheAudience
  extend ActiveSupport::Concern

  private

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
