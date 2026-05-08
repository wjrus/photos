require "net/http"
require "digest"

class LocationAddressGeocoder
  ENDPOINT = LocationReverseGeocoder::ENDPOINT
  CACHE_TTL = 30.days

  def initialize(api_key: LocationReverseGeocoder.api_key)
    @api_key = api_key
  end

  def geocode(address:)
    normalized_address = address.to_s.squish
    return if @api_key.blank? || normalized_address.blank?

    cache_key = "location-address-geocoder/v1/#{Digest::SHA256.hexdigest(normalized_address.downcase)}"
    cached = Rails.cache.read(cache_key)
    return cached.merge(key_fingerprint: api_key_fingerprint) if cached.present?

    uri = URI(ENDPOINT)
    uri.query = URI.encode_www_form(address: normalized_address, key: @api_key)

    response = Net::HTTP.get_response(uri)
    unless response.is_a?(Net::HTTPSuccess)
      Rails.logger.warn("Location address geocode HTTP failure: status=#{response.code} key=#{api_key_fingerprint}")
      return
    end

    payload = JSON.parse(response.body)
    unless payload["status"] == "OK"
      log_payload_status(payload)
      return
    end

    result = payload.fetch("results", []).first
    location = result&.dig("geometry", "location")
    return unless location

    geocoded = {
      latitude: BigDecimal(location.fetch("lat").to_s),
      longitude: BigDecimal(location.fetch("lng").to_s),
      name: result["formatted_address"].presence || normalized_address,
      names: place_names(result, normalized_address),
      raw: result
    }

    Rails.cache.write(cache_key, geocoded, expires_in: CACHE_TTL)
    geocoded.merge(key_fingerprint: api_key_fingerprint)
  rescue JSON::ParserError, KeyError, SocketError, SystemCallError, Timeout::Error => error
    Rails.logger.warn("Location address geocode error: #{error.class}: #{error.message} key=#{api_key_fingerprint}")
    nil
  end

  private

  def place_names(result, address)
    components = result.fetch("address_components", [])
    [
      result["formatted_address"],
      address,
      component_name(components, "neighborhood"),
      component_name(components, "sublocality_level_1"),
      component_name(components, "sublocality"),
      component_name(components, "postal_town"),
      component_name(components, "locality"),
      component_name(components, "administrative_area_level_3"),
      component_name(components, "administrative_area_level_2"),
      component_name(components, "administrative_area_level_1"),
      component_name(components, "country")
    ].compact_blank.uniq
  end

  def component_name(components, type)
    components.find { |component| component.fetch("types", []).include?(type) }&.fetch("long_name", nil)
  end

  def log_payload_status(payload)
    status = payload["status"].presence || "UNKNOWN"
    message = payload["error_message"].presence
    log_line = "Location address geocode failed: status=#{status} key=#{api_key_fingerprint}"
    log_line = "#{log_line} error=#{message}" if message

    if status == "ZERO_RESULTS"
      Rails.logger.info(log_line)
    else
      Rails.logger.warn(log_line)
    end
  end

  def api_key_fingerprint
    return "blank" if @api_key.blank?

    "#{@api_key.first(6)}...#{@api_key.last(4)}"
  end
end
