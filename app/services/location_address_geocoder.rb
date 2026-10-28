class LocationAddressGeocoder
  def initialize(api_key: LocationReverseGeocoder.api_key)
    @api_key = api_key
  end

  def geocode(address:)
    normalized_address = address.to_s.squish
    return if normalized_address.blank?

    client = LocationNativeGeocoder.new(api_key: @api_key)
    payload = client.address(address: normalized_address)
    return unless payload && payload["status"] == "OK"

    result = payload.fetch("results", []).first
    location = result&.dig("geometry", "location")
    return unless location

    latitude = BigDecimal(location.fetch("lat").to_s).round(6)
    longitude = BigDecimal(location.fetch("lng").to_s).round(6)
    context = client.reverse(latitude: latitude, longitude: longitude)
    result = LocationReverseGeocoder.native_context(result, Array(context&.fetch("results", [])))
    plus_code = result.fetch("types", []).include?("plus_code") || LocationReverseGeocoder.plus_code_name?(result["formatted_address"])
    identity = if result["place_id"].present? && !plus_code
      {
        identity_key: "google:#{result.fetch('place_id')}",
        provider: "google",
        provider_place_id: result.fetch("place_id"),
        place_type: result.fetch("types", []).find { |type| type != "political" } || "address"
      }
    else
      LocationReverseGeocoder.coordinate_identity(latitude: latitude, longitude: longitude)
    end
    name = if identity[:place_type] == "coordinate"
      if LocationReverseGeocoder.plus_code_name?(result["formatted_address"])
        result["formatted_address"]
      else
        LocationReverseGeocoder.coordinate_pair(latitude: latitude, longitude: longitude).join(", ")
      end
    else
      result["formatted_address"].presence || normalized_address
    end

    region = LocationMapRegion.for_result(result)
    geocoded = identity.merge(region).merge(
      latitude: latitude,
      longitude: longitude,
      name: name,
      names: [ name, *place_names(result, normalized_address), region[:map_region_name] ].compact_blank.uniq,
      raw: result
    )

    geocoded.merge(key_fingerprint: api_key_fingerprint)
  rescue LocationNativeGeocoder::LookupError, JSON::ParserError, KeyError, SocketError, SystemCallError, Timeout::Error => error
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

  def api_key_fingerprint
    return "blank" if @api_key.blank?

    "#{@api_key.first(6)}...#{@api_key.last(4)}"
  end
end
