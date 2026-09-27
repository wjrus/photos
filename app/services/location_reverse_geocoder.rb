require "net/http"

class LocationReverseGeocoder
  ENDPOINT = "https://maps.googleapis.com/maps/api/geocode/json".freeze
  CACHE_TTL = 30.days
  CACHE_VERSION = "v5".freeze
  GEOGRAPHY_TYPES = %w[
    neighborhood sublocality_level_5 sublocality_level_4 sublocality_level_3
    sublocality_level_2 sublocality_level_1 sublocality locality postal_town
    administrative_area_level_7 administrative_area_level_6 administrative_area_level_5
    administrative_area_level_4 administrative_area_level_3
  ].freeze
  LANDMARK_TYPES = %w[tourist_attraction point_of_interest establishment premise natural_feature park airport].freeze
  ALIAS_TYPES = (GEOGRAPHY_TYPES + %w[administrative_area_level_2 administrative_area_level_1 country]).freeze
  PLUS_CODE_PATTERN = /\A[23456789CFGHJMPQRVWX]{4,8}\+[23456789CFGHJMPQRVWX]{2,3}(?:\b|,|\s|\z)/i

  def self.api_key
    ENV["GOOGLE_MAPS_GEOCODING_API_KEY"].presence ||
      ENV["GOOGLE_GEOCODING_API_KEY"].presence ||
      ENV["GOOGLE_MAPS_EMBED_API_KEY"].presence
  end

  def self.plus_code_name?(name)
    name.to_s.match?(PLUS_CODE_PATTERN)
  end

  def self.coordinate_pair(latitude:, longitude:)
    [ latitude, longitude ].map do |value|
      rounded = BigDecimal(value.to_s).round(6)
      format("%.6f", rounded.zero? ? 0 : rounded)
    end
  end

  def self.coordinate_identity(latitude:, longitude:)
    {
      identity_key: "coordinate:#{coordinate_pair(latitude: latitude, longitude: longitude).join(',')}",
      provider: nil,
      provider_place_id: nil,
      place_type: "coordinate"
    }
  end

  def initialize(api_key: self.class.api_key)
    @api_key = api_key
  end

  def geocode(latitude:, longitude:)
    return unless @api_key.present?

    latitude, longitude = self.class.coordinate_pair(latitude: latitude, longitude: longitude)
    cache_key = "location-reverse-geocoder/#{CACHE_VERSION}/#{latitude},#{longitude}"
    cached = Rails.cache.read(cache_key)
    return cached.merge(key_fingerprint: api_key_fingerprint) if cached.present?

    payload = geocode_payload(latitude: latitude, longitude: longitude)
    return unless payload

    results = payload.fetch("results", [])
    candidate = canonical_result(results, latitude: latitude, longitude: longitude)
    if candidate
      result, type = candidate
      primary_name = feature_name(result, type)
      identity = {
        identity_key: "google:#{result.fetch('place_id')}",
        provider: "google",
        provider_place_id: result.fetch("place_id"),
        place_type: type
      }
    else
      result = results.find { |item| plus_code_name(item).present? } || results.first || {}
      primary_name = plus_code_name(result) || [ latitude, longitude ].join(", ")
      identity = self.class.coordinate_identity(latitude: latitude, longitude: longitude)
    end

    region = LocationMapRegion.for_result(result)
    names = [ *place_names(results, primary_name), region[:map_region_name] ].compact_blank.uniq
    geocoded = identity.merge(region).merge(name: primary_name, names: names, raw: result)
    Rails.cache.write(cache_key, geocoded, expires_in: CACHE_TTL)
    geocoded.merge(key_fingerprint: api_key_fingerprint)
  rescue JSON::ParserError, SocketError, SystemCallError, Timeout::Error => error
    Rails.logger.warn("Location reverse geocode error: #{error.class}: #{error.message} key=#{api_key_fingerprint}")
    nil
  end

  private

  def canonical_result(results, latitude:, longitude:)
    # A component label does not give us that component's place ID. Only an
    # actual result for the geography can identify a shared place. Counties,
    # states, and countries are useful aliases, but too broad to group photos.
    candidates = results.filter_map do |result|
      next if result["place_id"].blank? || result["partial_match"]
      next if result.fetch("types", []).include?("plus_code")

      type = canonical_type(result, latitude: latitude, longitude: longitude)
      next unless type && feature_name(result, type).present?

      [ result, type ]
    end
    candidates.min_by do |result, type|
      [ LANDMARK_TYPES.include?(type) ? -1 : GEOGRAPHY_TYPES.index(type), result.fetch("place_id") ]
    end
  end

  def canonical_type(result, latitude:, longitude:)
    types = result.fetch("types", [])
    landmark_type = LANDMARK_TYPES.find { |type| types.include?(type) }
    # Reverse geocoding may return the nearest address or attraction. A named
    # landmark only takes precedence when its point matches the stored GPS
    # precision; no distance threshold or nearby probe implies a visit.
    if landmark_type && landmark_name(result).present? && exact_point?(result, latitude: latitude, longitude: longitude)
      return landmark_type
    end

    GEOGRAPHY_TYPES.find { |type| types.include?(type) }
  end

  def exact_point?(result, latitude:, longitude:)
    location = result.dig("geometry", "location")
    return false unless location && location["lat"] && location["lng"]

    self.class.coordinate_pair(latitude: location["lat"], longitude: location["lng"]) == [ latitude, longitude ]
  end

  def feature_name(result, type)
    components = result.fetch("address_components", [])
    feature = LANDMARK_TYPES.include?(type) ? landmark_name(result) : component_name(components, type)
    return formatted_address_name(result["formatted_address"]) if feature.blank?

    locality = component_name(components, "locality") || component_name(components, "postal_town")
    region = component_name(components, "administrative_area_level_1") || component_name(components, "country")
    context = type.in?(%w[locality postal_town]) ? region : locality || region
    [ feature, context ].compact.uniq.join(", ")
  end

  def place_names(results, primary_name)
    aliases = results.flat_map do |result|
      components = result.fetch("address_components", [])
      ALIAS_TYPES.filter_map { |type| component_name(components, type) }
    end
    [ primary_name, *aliases ].compact_blank.reject { |name| self.class.plus_code_name?(name) }.uniq
  end

  def landmark_name(result)
    component = result.fetch("address_components", []).find do |item|
      (item.fetch("types", []) & LANDMARK_TYPES).any?
    end
    name = component&.fetch("long_name", nil).presence || result["formatted_address"].to_s.split(",", 2).first
    name if name.present? && !name.match?(/\A\d/) && !self.class.plus_code_name?(name)
  end

  def component_name(components, type)
    components.find { |component| component.fetch("types", []).include?(type) }&.fetch("long_name", nil)
  end

  def formatted_address_name(formatted_address)
    formatted_address.presence unless self.class.plus_code_name?(formatted_address)
  end

  def plus_code_name(result)
    [
      result["formatted_address"].to_s.split(",", 2).first,
      component_name(result.fetch("address_components", []), "plus_code")
    ].compact_blank.find { |name| self.class.plus_code_name?(name) }
  end

  def geocode_payload(latitude:, longitude:)
    uri = URI(ENDPOINT)
    uri.query = URI.encode_www_form(latlng: "#{latitude},#{longitude}", key: @api_key)
    response = Net::HTTP.get_response(uri)
    unless response.is_a?(Net::HTTPSuccess)
      Rails.logger.warn("Location reverse geocode HTTP failure: status=#{response.code} key=#{api_key_fingerprint}")
      return
    end

    payload = JSON.parse(response.body)
    unless payload["status"].in?(%w[OK ZERO_RESULTS])
      log_payload_status(payload)
      return
    end

    payload
  end

  def log_payload_status(payload)
    status = payload["status"].presence || "UNKNOWN"
    message = payload["error_message"].presence
    log_line = "Location reverse geocode failed: status=#{status} key=#{api_key_fingerprint}"
    log_line = "#{log_line} error=#{message}" if message
    Rails.logger.warn(log_line)
  end

  def api_key_fingerprint
    return "blank" if @api_key.blank?

    "#{@api_key.first(6)}...#{@api_key.last(4)}"
  end
end
