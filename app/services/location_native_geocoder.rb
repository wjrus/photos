require "net/http"
require "digest"

# Geocoding v4 defaults to the location's native language and script. Keep the
# complete provider response permanently, then adapt it for the existing matcher.
class LocationNativeGeocoder
  class LookupError < StandardError
    attr_reader :http_status

    def initialize(message, http_status: nil)
      @http_status = http_status
      super(message)
    end
  end
  ENDPOINT = "https://geocode.googleapis.com/v4/geocode".freeze
  VERSION = "native-v1".freeze

  def initialize(api_key: LocationReverseGeocoder.api_key)
    @api_key = api_key
  end

  def reverse(latitude:, longitude:)
    coordinates = LocationReverseGeocoder.coordinate_pair(latitude: latitude, longitude: longitude).join(",")
    payload = fetch("location/#{coordinates}")
    return unless payload

    results = Array(payload["results"]).map { |result| normalize(result) }
    { "status" => results.empty? ? "ZERO_RESULTS" : "OK", "results" => results }
  end

  def place(place_id:)
    return if place_id.blank? || place_id.bytesize > 1_024

    payload = fetch("places/#{ERB::Util.url_encode(place_id)}")
    normalize(payload) if payload
  end

  def address(address:)
    payload = fetch("address/#{ERB::Util.url_encode(address.to_s.squish)}")
    return unless payload

    results = Array(payload["results"]).map { |result| normalize(result) }
    { "status" => results.empty? ? "ZERO_RESULTS" : "OK", "results" => results }
  end

  private

  def fetch(path)
    cache_key = "google-geocoding-v4/#{VERSION}/#{Digest::SHA256.hexdigest(path)}"
    LocationGeocodingResponse.fetch(cache_key) do
      raise LookupError, "Configure a server geocoding key before requesting uncached native names" if @api_key.blank?

      uri = URI("#{ENDPOINT}/#{path}")
      request = Net::HTTP::Get.new(uri)
      request["X-Goog-Api-Key"] = @api_key
      LocationApiBudget.reserve!(:geocoding)
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 3, read_timeout: 12) { |http| http.request(request) }
      unless response.is_a?(Net::HTTPSuccess)
        raise LookupError.new("Native geocoding failed: HTTP #{response.code}", http_status: response.code.to_i)
      end

      payload = JSON.parse(response.body)
      valid = if path.start_with?("places/")
        valid_result?(payload) && payload["placeId"].is_a?(String) && payload["placeId"].present?
      else
        payload.is_a?(Hash) && payload.fetch("results", []).is_a?(Array) && payload.fetch("results", []).all? { |result| valid_result?(result) }
      end
      raise LookupError, "Native geocoding returned an invalid response" unless valid

      payload
    end
  rescue JSON::ParserError, SocketError, SystemCallError, Timeout::Error, Net::HTTPBadResponse => error
    raise LookupError, "Native geocoding failed: #{error.class}"
  end

  def valid_result?(result)
    result.is_a?(Hash) && (result["placeId"].nil? || result["placeId"].is_a?(String)) && (!result.key?("types") || result["types"].is_a?(Array)) &&
      (!result.key?("addressComponents") || (result["addressComponents"].is_a?(Array) && result["addressComponents"].all? { |component| component.is_a?(Hash) }))
  end

  def normalize(result)
    components = Array(result["addressComponents"]).map do |component|
      { "long_name" => component["longText"], "short_name" => component["shortText"],
        "types" => Array(component["types"]), "language_code" => component["languageCode"] }.compact
    end
    geometry = { "location" => { "lat" => result.dig("location", "latitude"), "lng" => result.dig("location", "longitude") } }
    %w[bounds viewport].each do |field|
      next unless result[field].is_a?(Hash)

      geometry[field] = {
        "southwest" => { "lat" => result.dig(field, "low", "latitude"), "lng" => result.dig(field, "low", "longitude") },
        "northeast" => { "lat" => result.dig(field, "high", "latitude"), "lng" => result.dig(field, "high", "longitude") }
      }
    end
    { "place_id" => result["placeId"], "types" => Array(result["types"]), "formatted_address" => result["formattedAddress"],
      "address_components" => components, "geometry" => geometry, "partial_match" => result["partialMatch"],
      "source" => "google_geocoding_v4", "native_name_version" => VERSION }
  end
end
