require "net/http"

class LocationReverseGeocoder
  ENDPOINT = "https://maps.googleapis.com/maps/api/geocode/json".freeze
  CACHE_TTL = 30.days
  NEARBY_FALLBACK_RADII_KM = [ 2, 10, 25 ].freeze
  NEARBY_FALLBACK_BEARINGS = [ 0, 90, 180, 270, 45, 135, 225, 315 ].freeze
  NEARBY_FALLBACK_ENABLED_ENV = "LOCATION_GEOCODER_NEARBY_FALLBACK".freeze
  NEARBY_FALLBACK_DAILY_LIMIT_ENV = "LOCATION_GEOCODER_NEARBY_FALLBACK_DAILY_LIMIT".freeze
  NEARBY_FALLBACK_MAX_PROBES_ENV = "LOCATION_GEOCODER_NEARBY_FALLBACK_MAX_PROBES".freeze
  NEARBY_FALLBACK_DEFAULT_DAILY_LIMIT = 25
  NEARBY_FALLBACK_DEFAULT_MAX_PROBES = 9
  EARTH_RADIUS_KM = 6_371.0
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
  PLUS_CODE_PATTERN = /\A[23456789CFGHJMPQRVWX]{4,8}\+[23456789CFGHJMPQRVWX]{2,3}(?:\b|,|\s|\z)/i

  def self.api_key
    ENV["GOOGLE_MAPS_GEOCODING_API_KEY"].presence ||
      ENV["GOOGLE_GEOCODING_API_KEY"].presence ||
      ENV["GOOGLE_MAPS_EMBED_API_KEY"].presence
  end

  def self.plus_code_name?(name)
    name.to_s.match?(PLUS_CODE_PATTERN)
  end

  def initialize(api_key: self.class.api_key)
    @api_key = api_key
  end

  def geocode(latitude:, longitude:)
    return unless @api_key.present?

    cache_key = "location-reverse-geocoder/v2/#{format('%.5f', latitude.to_f)},#{format('%.5f', longitude.to_f)}"
    cached = Rails.cache.read(cache_key)
    return cached if cached.present?

    match = geocode_result(latitude: latitude, longitude: longitude)
    return unless match

    result = match.fetch(:result)
    primary_name = primary_name_for_result(result, nearby: match.fetch(:nearby))
    return if primary_name.blank?

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

  def geocode_result(latitude:, longitude:)
    exact_payload = geocode_payload(latitude: latitude, longitude: longitude)
    return unless exact_payload

    exact_result = exact_payload.fetch("results", []).find { |result| usable_result?(result) }
    return { result: exact_result, nearby: false } if exact_result

    if nearby_fallback_enabled?
      nearby_result = nearby_result(latitude: latitude.to_f, longitude: longitude.to_f)
      return nearby_result if nearby_result
    end

    plus_code_result = exact_payload.fetch("results", []).find { |result| plus_code_result?(result) }
    { result: plus_code_result, nearby: false } if plus_code_result
  end

  def nearby_result(latitude:, longitude:)
    nearby_coordinates(latitude: latitude, longitude: longitude).take(nearby_fallback_max_probes).lazy.filter_map do |nearby_latitude, nearby_longitude|
      next unless reserve_nearby_fallback_request

      payload = geocode_payload(latitude: nearby_latitude, longitude: nearby_longitude)
      result = payload&.fetch("results", [])&.find { |candidate| usable_result?(candidate) }
      { result: result, nearby: true } if result
    end.first
  end

  def nearby_fallback_enabled?
    ActiveModel::Type::Boolean.new.cast(ENV[NEARBY_FALLBACK_ENABLED_ENV])
  end

  def nearby_fallback_max_probes
    Integer(ENV.fetch(NEARBY_FALLBACK_MAX_PROBES_ENV, NEARBY_FALLBACK_DEFAULT_MAX_PROBES)).clamp(0, NEARBY_FALLBACK_RADII_KM.size * NEARBY_FALLBACK_BEARINGS.size)
  rescue ArgumentError, TypeError
    NEARBY_FALLBACK_DEFAULT_MAX_PROBES
  end

  def reserve_nearby_fallback_request
    limit = nearby_fallback_daily_limit
    return false if limit <= 0

    cache_key = "location-reverse-geocoder/nearby-fallback-count/#{Time.zone.today.iso8601}"
    count = Rails.cache.read(cache_key).to_i
    return false if count >= limit

    Rails.cache.write(cache_key, count + 1, expires_in: 2.days)
  end

  def nearby_fallback_daily_limit
    Integer(ENV.fetch(NEARBY_FALLBACK_DAILY_LIMIT_ENV, NEARBY_FALLBACK_DEFAULT_DAILY_LIMIT)).clamp(0, 10_000)
  rescue ArgumentError, TypeError
    NEARBY_FALLBACK_DEFAULT_DAILY_LIMIT
  end

  def geocode_payload(latitude:, longitude:)
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

    payload
  end

  def nearby_coordinates(latitude:, longitude:)
    NEARBY_FALLBACK_BEARINGS.flat_map do |bearing_degrees|
      NEARBY_FALLBACK_RADII_KM.map do |radius_km|
        destination_coordinate(latitude: latitude, longitude: longitude, radius_km: radius_km, bearing_degrees: bearing_degrees)
      end
    end
  end

  def destination_coordinate(latitude:, longitude:, radius_km:, bearing_degrees:)
    angular_distance = radius_km.to_f / EARTH_RADIUS_KM
    bearing = bearing_degrees.to_f * Math::PI / 180
    latitude_radians = latitude.to_f * Math::PI / 180
    longitude_radians = longitude.to_f * Math::PI / 180

    destination_latitude = Math.asin(
      (Math.sin(latitude_radians) * Math.cos(angular_distance)) +
        (Math.cos(latitude_radians) * Math.sin(angular_distance) * Math.cos(bearing))
    )
    destination_longitude = longitude_radians + Math.atan2(
      Math.sin(bearing) * Math.sin(angular_distance) * Math.cos(latitude_radians),
      Math.cos(angular_distance) - (Math.sin(latitude_radians) * Math.sin(destination_latitude))
    )

    [
      destination_latitude * 180 / Math::PI,
      normalized_longitude(destination_longitude * 180 / Math::PI)
    ]
  end

  def normalized_longitude(longitude)
    ((longitude + 540) % 360) - 180
  end

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
        formatted_address_name(result["formatted_address"])
    end
  end

  def primary_name_for_result(result, nearby:)
    name = place_name(result) || plus_code_name(result)
    return if name.blank?
    return name unless nearby

    "Near #{name}"
  end

  def place_names(result, primary_name)
    result_name = place_name(result)
    components = result.fetch("address_components", [])
    [
      primary_name,
      result_name,
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
    ].compact_blank.reject { |name| self.class.plus_code_name?(name) }.uniq
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
    return if first_part.blank? || first_part.match?(/\A\d/) || self.class.plus_code_name?(first_part)

    first_part
  end

  def formatted_address_name(formatted_address)
    formatted_address.presence unless self.class.plus_code_name?(formatted_address)
  end

  def usable_result?(result)
    return false if result.fetch("types", []).include?("plus_code")

    place_name(result).present?
  end

  def plus_code_result?(result)
    result.fetch("types", []).include?("plus_code") || plus_code_name(result).present?
  end

  def plus_code_name(result)
    [
      result["formatted_address"].to_s.split(",", 2).first,
      component_name(result.fetch("address_components", []), "plus_code")
    ].compact_blank.find { |name| self.class.plus_code_name?(name) }
  end

  def api_key_fingerprint
    return "blank" if @api_key.blank?

    "#{@api_key.first(6)}...#{@api_key.last(4)}"
  end
end
