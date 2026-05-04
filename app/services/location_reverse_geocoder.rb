require "net/http"

class LocationReverseGeocoder
  ENDPOINT = "https://maps.googleapis.com/maps/api/geocode/json".freeze

  def initialize(api_key: ENV["GOOGLE_MAPS_EMBED_API_KEY"])
    @api_key = api_key
  end

  def geocode(latitude:, longitude:)
    return unless @api_key.present?

    uri = URI(ENDPOINT)
    uri.query = URI.encode_www_form(
      latlng: "#{latitude.to_f},#{longitude.to_f}",
      key: @api_key,
      result_type: "locality|sublocality|neighborhood|administrative_area_level_3|administrative_area_level_2"
    )

    response = Net::HTTP.get_response(uri)
    return unless response.is_a?(Net::HTTPSuccess)

    payload = JSON.parse(response.body)
    result = payload.fetch("results", []).first
    return unless result

    {
      name: place_name(result),
      raw: result
    }
  rescue JSON::ParserError, SocketError, SystemCallError, Timeout::Error
    nil
  end

  private

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
end
