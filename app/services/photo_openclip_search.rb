require "set"

class PhotoOpenclipSearch
  DEFAULT_LIMIT = 200
  CACHE_TTL = 30.minutes

  def self.available_for?(user)
    user&.owner? &&
      AppSetting.boolean(AppSetting::ANALYSIS_OPENCLIP_ENABLED, default: false) &&
      current_embeddings.exists?
  end

  def self.search_ids(query:, user:, limit: DEFAULT_LIMIT)
    return [] unless available_for?(user)

    normalized_query = query.to_s.strip.downcase
    return [] if normalized_query.blank?

    Rails.cache.fetch(cache_key(query: normalized_query, user: user, limit: limit), expires_in: CACHE_TTL) do
      new(query: normalized_query, user: user, limit: limit).search_ids
    end
  end

  def initialize(query:, user:, limit: DEFAULT_LIMIT, client: PhotoAnalysisLocalClient.new)
    @query = query.to_s.strip
    @user = user
    @limit = Integer(limit).clamp(1, DEFAULT_LIMIT)
    @client = client
  end

  def search_ids
    return [] if query.blank? || !self.class.available_for?(user)

    ranked_ids = ranked_photo_ids
    return [] if ranked_ids.empty?

    visible_current_ids = Set.new(
      Photo
        .visible_to(user)
        .where(id: ranked_ids)
        .where(id: self.class.current_embeddings.select(:photo_id))
        .pluck(:id)
    )
    ranked_ids.select { |photo_id| visible_current_ids.include?(photo_id) }
  rescue PhotoAnalysisLocalClient::Error, Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNREFUSED => error
    Rails.logger.warn("OpenCLIP semantic search failed: #{error.message}")
    []
  end

  def self.current_embeddings
    PhotoEmbedding.where(
      provider: "openclip",
      model: openclip_model,
      model_version: openclip_model_version
    )
  end

  def self.openclip_model
    ENV.fetch("OPENCLIP_MODEL", "ViT-B-32")
  end

  def self.openclip_model_version
    ENV.fetch("OPENCLIP_PRETRAINED", "laion2b_s34b_b79k")
  end

  def self.cache_key(query:, user:, limit:)
    [
      "openclip-search",
      openclip_model,
      openclip_model_version,
      user.id,
      query,
      limit,
      current_embeddings.maximum(:embedded_at)&.to_i,
      current_embeddings.count
    ]
  end

  private

  attr_reader :query, :user, :limit, :client

  def ranked_photo_ids
    response = client.openclip_search(query: query, limit: limit)
    Array(response["results"] || response[:results]).filter_map do |result|
      (result["photo_id"] || result[:photo_id])&.to_i
    end
  end
end
