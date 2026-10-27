# Durable provider responses, independent of Rails.cache eviction and matching
# algorithm versions. Request keys describe the API request, never its key.
class LocationGeocodingResponse < ApplicationRecord
  validates :request_key, presence: true

  def self.fetch(request_key)
    cached = find_by(request_key: request_key)
    return cached.payload if cached

    payload = yield
    return if payload.nil?

    create_or_find_by!(request_key: request_key) { |record| record.payload = payload }.payload
  end
end
