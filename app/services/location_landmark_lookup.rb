require "net/http"

# Optional paid POI lookup for automatic matches that only have coordinate names.
class LocationLandmarkLookup
  class LookupError < StandardError; end
  ENDPOINT = "https://places.googleapis.com/v1/places:searchNearby".freeze
  TYPES = %w[tourist_attraction historical_landmark observation_deck hiking_area campground visitor_center mountain_peak scenic_spot nature_preserve national_park park].freeze
  MAX_DISTANCE_METERS = 500

  def self.api_key
    ENV["GOOGLE_MAPS_PLACES_API_KEY"].presence || LocationReverseGeocoder.api_key
  end

  def initialize(api_key: self.class.api_key)
    @api_key = api_key
  end

  def geocode(latitude:, longitude:, language_code: nil, country_code: nil)
    latitude, longitude = Float(latitude), Float(longitude)
    return unless latitude.finite? && longitude.finite? && (-90..90).cover?(latitude) && (-180..180).cover?(longitude)

    # A shared ~100m search cell reuses results for adjacent photos. Distances
    # are checked again against each actual GPS point, not the cached center.
    lat, lng = latitude.round(3), longitude.round(3)
    language_code = language_code.presence
    return if language_code && !language_code.match?(/\A[a-zA-Z]{2,3}(?:-[a-zA-Z0-9]{2,8})*\z/)

    places = LocationGeocodingResponse.fetch("google-places-nearby/v2/#{language_code || 'default'}/#{lat},#{lng}") do
      raise LookupError, "Configure a server key with Places API (New) enabled before refreshing landmark names." if @api_key.blank?

      request_places(lat, lng, language_code)
    end
    return unless places.is_a?(Array)

    candidate = places.filter_map do |place|
      next unless place.is_a?(Hash) && place["id"].is_a?(String) && place["id"].present?
      next unless place["displayName"].is_a?(Hash) && place["location"].is_a?(Hash) && place.dig("displayName", "text").is_a?(String)
      next if (Array(place["types"]) & TYPES).empty? || place.dig("displayName", "text").blank?
      place_country = Array(place["addressComponents"]).find { |component| Array(component["types"]).include?("country") }&.fetch("shortText", nil)
      next if country_code.present? && place_country.present? && !country_code.casecmp?(place_country)

      distance = PhotoLocation.distance_meters(latitude, longitude, place.dig("location", "latitude"), place.dig("location", "longitude"))
      [ place, distance ] if distance && distance <= MAX_DISTANCE_METERS
    end.min_by { |place, distance| [ distance, place.fetch("id") ] }
    return unless candidate

    place = candidate.first
    name = place.dig("displayName", "text").first(500)
    components = Array(place["addressComponents"]).filter_map do |component|
      next unless component.is_a?(Hash) && component["longText"].is_a?(String)

      { "long_name" => component["longText"], "short_name" => component["shortText"], "types" => Array(component["types"]), "language_code" => component["languageCode"] }.compact
    end
    raw = { "place_id" => place.fetch("id"), "types" => place.fetch("types"),
      "formatted_address" => place["formattedAddress"].presence || name, "address_components" => components,
      "geometry" => { "location" => { "lat" => place.dig("location", "latitude"), "lng" => place.dig("location", "longitude") } },
      "source" => "google_places_nearby", "distance_meters" => candidate.last.round }
    raw["native_name_version"] = LocationNativeGeocoder::VERSION if language_code.present?
    region = LocationMapRegion.for_result(raw)
    {
      identity_key: "google:#{place.fetch('id')}", provider: "google", provider_place_id: place.fetch("id"),
      place_type: "nearby_landmark", name: name,
      names: [ name, place["formattedAddress"], *components.map { |component| component["long_name"] }, region[:map_region_name] ].compact_blank.uniq,
      raw: raw
    }.merge(region)
  rescue ArgumentError, TypeError
    nil
  end

  private

  def request_places(latitude, longitude, language_code)
    uri = URI(ENDPOINT)
    request = Net::HTTP::Post.new(uri)
    request["Content-Type"] = "application/json"
    request["X-Goog-Api-Key"] = @api_key
    request["X-Goog-FieldMask"] = "places.id,places.displayName,places.types,places.location,places.addressComponents,places.formattedAddress"
    body = {
      includedTypes: TYPES, maxResultCount: 10, rankPreference: "DISTANCE",
      locationRestriction: { circle: { center: { latitude: latitude, longitude: longitude }, radius: 600 } }
    }
    body[:languageCode] = language_code if language_code.present?
    request.body = body.to_json
    LocationApiBudget.reserve!(:places_nearby)
    response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 3, read_timeout: 8) { |http| http.request(request) }
    unless response.is_a?(Net::HTTPSuccess)
      raise LookupError, "Nearby landmark lookup failed: HTTP #{response.code}. Check Places API (New) access and quota for the server key."
    end

    payload = JSON.parse(response.body)
    unless payload.is_a?(Hash) && payload.fetch("places", []).is_a?(Array)
      raise LookupError, "Nearby landmark lookup returned an invalid response."
    end

    payload.fetch("places", [])
  rescue JSON::ParserError, SocketError, SystemCallError, Timeout::Error, Net::HTTPBadResponse => error
    raise LookupError, "Nearby landmark lookup failed: #{error.class}"
  end
end
