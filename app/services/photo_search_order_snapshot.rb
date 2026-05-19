class PhotoSearchOrderSnapshot
  CACHE_PREFIX = "photo-search-order"
  TTL = 30.minutes
  MAX_IDS = 10_000
  TOKEN_LENGTH = 24

  def self.store(scope:, user:, token: nil)
    new(user: user, token: token).store(scope)
  end

  def self.neighbor_ids(token:, user:, photo_id:)
    new(user: user, token: token).neighbor_ids(photo_id)
  end

  def initialize(user:, token: nil)
    @user = user
    @token = usable_token(token) || SecureRandom.urlsafe_base64(TOKEN_LENGTH)
  end

  attr_reader :token

  def store(scope)
    ids = scope.limit(MAX_IDS).to_a.map(&:id)
    return nil if ids.empty?

    Rails.cache.write(cache_key, { "user_key" => user_key, "ids" => ids }, expires_in: TTL)
    token
  end

  def neighbor_ids(photo_id)
    payload = Rails.cache.read(cache_key)
    return unless payload&.fetch("user_key", nil) == user_key

    ids = Array(payload["ids"]).map(&:to_i)
    index = ids.index(photo_id.to_i)
    return unless index

    {
      previous_id: (ids[index - 1] if index.positive?),
      next_id: ids[index + 1]
    }
  end

  private

  attr_reader :user

  def usable_token(value)
    token = value.to_s
    token if token.match?(/\A[-_A-Za-z0-9]{16,128}\z/)
  end

  def cache_key
    [ CACHE_PREFIX, token ]
  end

  def user_key
    user ? "user:#{user.id}" : "public"
  end
end
