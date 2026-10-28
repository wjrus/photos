# Existing matcher tests describe normalized results. Render those fixtures as
# provider-v4 JSON so they continue exercising the real transport adapter.
module NativeGeocodingFixtures
  def native_http_response(payload)
    status = payload[:status] || payload["status"]
    response = status.in?(%w[OK ZERO_RESULTS]) ? Net::HTTPOK.new("1.1", "200", "OK") : Net::HTTPForbidden.new("1.1", "403", "Forbidden")
    response.instance_variable_set(:@read, true)
    results = JSON.parse(payload.to_json).fetch("results", []).map do |result|
      native = {
        placeId: result["place_id"], types: result.fetch("types", []), formattedAddress: result["formatted_address"], partialMatch: result["partial_match"],
        addressComponents: result.fetch("address_components", []).map { |item| { longText: item["long_name"], shortText: item["short_name"], types: item["types"] } }
      }
      geometry = result.fetch("geometry", {})
      native[:location] = { latitude: geometry.dig("location", "lat"), longitude: geometry.dig("location", "lng") }
      %w[bounds viewport].each do |field|
        next unless geometry[field]

        native[field] = { low: { latitude: geometry.dig(field, "southwest", "lat"), longitude: geometry.dig(field, "southwest", "lng") }, high: { latitude: geometry.dig(field, "northeast", "lat"), longitude: geometry.dig(field, "northeast", "lng") } }
      end
      native
    end
    response.body = (response.is_a?(Net::HTTPSuccess) ? { results: results } : { error: { status: "PERMISSION_DENIED" } }).to_json
    response
  end

  def with_native_responses(responses)
    calls = 0
    original = Net::HTTP.method(:start)
    http = Object.new
    http.define_singleton_method(:request) do |_request|
      response = responses.fetch(calls)
      calls += 1
      response
    end
    Net::HTTP.define_singleton_method(:start) { |*_args, **_options, &block| block.call(http) }
    yield
    calls
  ensure
    Net::HTTP.define_singleton_method(:start, original)
  end
end
