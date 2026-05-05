require "net/http"

class LocationReverseGeocoder
  ENDPOINT = "https://maps.googleapis.com/maps/api/geocode/json".freeze
  CACHE_TTL = 30.days
  LARGE_LOCALITIES = [
    "Chicago",
    "Cleveland",
    "Detroit",
    "London",
    "Los Angeles",
    "New York",
    "Paris",
    "San Francisco",
    "Toronto",
    "Washington"
  ].freeze

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

    cache_key = "location-reverse-geocoder/v2/#{format('%.5f', latitude.to_f)},#{format('%.5f', longitude.to_f)}"
    cached = Rails.cache.read(cache_key)
    return cached if cached.present?

    uri = URI(ENDPOINT)
    uri.query = URI.encode_www_form(
      latlng: "#{latitude.to_f},#{longitude.to_f}",
      key: @api_key
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

    primary_name = place_name(result)
    geocoded = {
      name: primary_name,
      names: place_names(result, primary_name),
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
    locality = component_name(components, "postal_town") ||
      component_name(components, "locality") ||
      component_name(components, "administrative_area_level_3")
    neighborhood = component_name(components, "neighborhood") ||
      component_name(components, "sublocality_level_1") ||
      component_name(components, "sublocality")
    landmark = landmark_name(result, components)
    county = component_name(components, "administrative_area_level_2")
    region = component_name(components, "administrative_area_level_1")
    country = component_name(components, "country")

    if landmark.present?
      [ landmark, locality || county || region || country ].compact.uniq.join(", ")
    elsif locality.in?(LARGE_LOCALITIES) && neighborhood.present?
      [ neighborhood, locality ].compact.uniq.join(", ")
    else
      [ locality || neighborhood || county, region || country ].compact.uniq.join(", ").presence ||
        result["formatted_address"].presence
    end
  end

  def place_names(result, primary_name)
    components = result.fetch("address_components", [])
    [
      primary_name,
      landmark_name(result, components),
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

  def landmark_name(result, components)
    result_types = result.fetch("types", [])
    landmark_types = %w[establishment point_of_interest tourist_attraction premise]
    return unless (result_types & landmark_types).any?

    component = components.find { |address_component| (address_component.fetch("types", []) & landmark_types).any? }
    component&.fetch("long_name", nil).presence || formatted_address_landmark(result["formatted_address"])
  end

  def formatted_address_landmark(formatted_address)
    first_part = formatted_address.to_s.split(",", 2).first
    return if first_part.blank? || first_part.match?(/\A\d/)

    first_part
  end

  def api_key_fingerprint
    return "blank" if @api_key.blank?

    "#{@api_key.first(6)}...#{@api_key.last(4)}"
  end
end
