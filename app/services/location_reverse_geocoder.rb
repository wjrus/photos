class LocationReverseGeocoder
  NEARBY_LANDMARK_TYPES = %w[natural_feature tourist_attraction].freeze
  NEARBY_LANDMARK_METERS = 500
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
    latitude, longitude = self.class.coordinate_pair(latitude: latitude, longitude: longitude)
    payload = LocationNativeGeocoder.new(api_key: @api_key).reverse(latitude: latitude, longitude: longitude)
    return unless payload

    results = payload.fetch("results", [])
    candidate = canonical_result(results, latitude: latitude, longitude: longitude)
    build_result(results, candidate, latitude: latitude, longitude: longitude)
  rescue LocationNativeGeocoder::LookupError => error
    Rails.logger.warn(error.message)
    nil
  end

  def localize(place_id:, latitude:, longitude:)
    client = LocationNativeGeocoder.new(api_key: @api_key)
    payload = client.reverse(latitude: latitude, longitude: longitude)
    return unless payload

    results = payload.fetch("results", [])
    result = results.find { |candidate| candidate["place_id"] == place_id } || client.place(place_id: place_id)
    return unless result && result["place_id"] == place_id

    type = (GEOGRAPHY_TYPES + LANDMARK_TYPES + %w[street_address]).find { |candidate| result.fetch("types", []).include?(candidate) }
    return unless type

    build_result(results, [ result, type ], latitude: latitude, longitude: longitude)
  end

  def named_area(query:)
    payload = LocationNativeGeocoder.new(api_key: @api_key).address(address: query)
    results = Array(payload&.fetch("results", []))
    result = results.find { |item| (Array(item["types"]) & %w[natural_feature national_park nature_preserve]).any? && item.dig("geometry", "bounds").present? && !item["partial_match"] }
    return unless result

    type = (Array(result["types"]) & %w[natural_feature national_park nature_preserve]).first
    point = result.dig("geometry", "location")
    build_result(results, [ result, type ], latitude: point.fetch("lat"), longitude: point.fetch("lng"))
  end

  private

  def build_result(results, candidate, latitude:, longitude:)
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

    result = self.class.native_context(result, results)
    region = LocationMapRegion.for_result(result)
    names = [ *place_names(results, primary_name), region[:map_region_name] ].compact_blank.uniq
    geocoded = identity.merge(region).merge(name: primary_name, names: names, raw: result)
    geocoded = LocationGroupingResolver.resolve(geocoded, latitude: latitude, longitude: longitude, context: results)
    geocoded.merge(key_fingerprint: api_key_fingerprint)
  rescue JSON::ParserError, SocketError, SystemCallError, Timeout::Error => error
    Rails.logger.warn("Location reverse geocode error: #{error.class}: #{error.message} key=#{api_key_fingerprint}")
    nil
  end

  public

  def self.native_context(result, results)
    return result unless result["native_name_version"] == LocationNativeGeocoder::VERSION

    components = Array(result["address_components"]).map(&:dup)
    %w[country administrative_area_level_1 administrative_area_level_2 locality postal_town].each do |type|
      next if components.any? { |component| Array(component["types"]).include?(type) }

      candidates = results.flat_map { |item| Array(item["address_components"]) }.select { |component| Array(component["types"]).include?(type) && component["long_name"].present? }
      components << candidates.first if candidates.map { |component| component["long_name"].unicode_normalize(:nfc).squish.downcase }.uniq.one?
    end
    result = result.merge("address_components" => components)
    component_name = ->(items, type) { items.find { |component| Array(component["types"]).include?(type) }&.fetch("long_name", nil) }
    country_code = ->(items) { items.find { |component| Array(component["types"]).include?("country") }&.fetch("short_name", nil) }
    city = component_name.call(components, "locality") || component_name.call(components, "postal_town")
    return result if city.blank?

    candidates = results.select do |item|
      type = (Array(item["types"]) & %w[locality postal_town]).first
      code = country_code.call(Array(item["address_components"]))
      type && item["place_id"].present? && code.present? && code == country_code.call(components) &&
        component_name.call(Array(item["address_components"]), type).to_s.squish.casecmp?(city.squish)
    end
    return result unless candidates.map { |item| item["place_id"] }.uniq.one?

    result.merge("native_locality" => { "place_id" => candidates.first["place_id"], "name" => city, "source" => "reverse_geocoding" })
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
    precise = candidates.min_by do |result, type|
      [ LANDMARK_TYPES.include?(type) ? -1 : GEOGRAPHY_TYPES.index(type), result.fetch("place_id") ]
    end
    return precise if precise && (LANDMARK_TYPES.include?(precise.last) || !precise.last.start_with?("administrative_area_"))

    # A scenic feature returned for this point can name its immediate vicinity.
    # Generic establishments and distant attractions still cannot imply a visit.
    nearby = results.filter_map do |result|
      next if result["place_id"].blank? || result["partial_match"]

      type = NEARBY_LANDMARK_TYPES.find { |candidate| result.fetch("types", []).include?(candidate) }
      next unless type && landmark_name(result).present?

      distance = landmark_distance(result, latitude: latitude, longitude: longitude)
      next unless distance && distance <= NEARBY_LANDMARK_METERS
      next if outside_feature_bounds?(result, latitude: latitude.to_f, longitude: longitude.to_f)

      [ result, type, distance ]
    end.min_by { |result, _type, distance| [ distance, result.fetch("place_id") ] }
    nearby ? nearby.first(2) : precise
  end

  def landmark_distance(result, latitude:, longitude:)
    point = result.dig("geometry", "location")
    return unless point

    PhotoLocation.distance_meters(latitude, longitude, point.fetch("lat"), point.fetch("lng"))
  rescue KeyError, ArgumentError, TypeError
    nil
  end

  def outside_feature_bounds?(result, latitude:, longitude:)
    bounds = result.dig("geometry", "bounds")
    return false unless bounds

    south, north = Float(bounds.dig("southwest", "lat")), Float(bounds.dig("northeast", "lat"))
    west, east = Float(bounds.dig("southwest", "lng")), Float(bounds.dig("northeast", "lng"))
    !latitude.between?(south, north) || !(west <= east ? longitude.between?(west, east) : longitude >= west || longitude <= east)
  rescue ArgumentError, TypeError
    true
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

  def api_key_fingerprint
    return "blank" if @api_key.blank?

    "#{@api_key.first(6)}...#{@api_key.last(4)}"
  end
end
