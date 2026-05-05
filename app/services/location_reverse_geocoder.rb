require "net/http"

class LocationReverseGeocoder
  ENDPOINT = "https://maps.googleapis.com/maps/api/geocode/json".freeze
  CACHE_TTL = 30.days

  def self.api_key
    ENV["GOOGLE_MAPS_GEOCODING_API_KEY"].presence ||
      ENV["GOOGLE_GEOCODING_API_KEY"].presence ||
      ENV["GOOGLE_MAPS_EMBED_API_KEY"].presence
  end

  def initialize(api_key: self.class.api_key)
    @api_key = api_key
  end

  def geocode(latitude:, longitude:)
    return unless @api_key.present?

    cache_key = "location-reverse-geocoder/v1/#{format('%.5f', latitude.to_f)},#{format('%.5f', longitude.to_f)}"
    cached = Rails.cache.read(cache_key)
    return cached if cached.present?

    uri = URI(ENDPOINT)
    uri.query = URI.encode_www_form(
      latlng: "#{latitude.to_f},#{longitude.to_f}",
      key: @api_key,
      result_type: "locality|sublocality|neighborhood|administrative_area_level_3|administrative_area_level_2"
    )

    response = Net::HTTP.get_response(uri)
    unless response.is_a?(Net::HTTPSuccess)
      Rails.logger.warn("Location reverse geocode HTTP failure: status=#{response.code} key=#{api_key_fingerprint}")
      return
    end

    payload = JSON.parse(response.body)
    unless payload["status"] == "OK"
      log_payload_status(payload)
      return
    end

    result = payload.fetch("results", []).first
    return unless result

    geocoded = {
      name: place_name(result),
      raw: result
    }

    Rails.cache.write(cache_key, geocoded, expires_in: CACHE_TTL) if geocoded[:name].present?
    geocoded.merge(key_fingerprint: api_key_fingerprint)
  rescue JSON::ParserError, SocketError, SystemCallError, Timeout::Error => error
    Rails.logger.warn("Location reverse geocode error: #{error.class}: #{error.message} key=#{api_key_fingerprint}")
    nil
  end

  private

  def log_payload_status(payload)
    status = payload["status"].presence || "UNKNOWN"
    message = payload["error_message"].presence
    log_line = "Location reverse geocode failed: status=#{status} key=#{api_key_fingerprint}"
    log_line = "#{log_line} error=#{message}" if message

    if status == "ZERO_RESULTS"
      Rails.logger.info(log_line)
    else
      Rails.logger.warn(log_line)
    end
  end

  def place_name(result)
    components = result.fetch("address_components", [])
    locality = component_name(components, "locality") ||
      component_name(components, "sublocality") ||
      component_name(components, "neighborhood")
    region = component_name(components, "administrative_area_level_1")
    country = component_name(components, "country")

    [ locality, region || country ].compact.uniq.join(", ").presence ||
      result["formatted_address"].presence
  end

  def component_name(components, type)
    components.find { |component| component.fetch("types", []).include?(type) }&.fetch("long_name", nil)
  end

  def api_key_fingerprint
    return "blank" if @api_key.blank?

    "#{@api_key.first(6)}...#{@api_key.last(4)}"
  end
end
