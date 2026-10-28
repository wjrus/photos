require "test_helper"

class LocationApiRequestTest < ActiveSupport::TestCase
  test "transient failures recover and every attempt is budgeted while the successful response stays cached" do
    with_http([ Net::OpenTimeout.new, response("503"), response("200") ]) do |requests, delays, options|
      LocationApiBudget.with_repair_limit(cents: 2) do
        client = LocationNativeGeocoder.new(api_key: "synthetic-key")
        2.times { assert_equal "ZERO_RESULTS", client.reverse(latitude: 44, longitude: -80)["status"] }
      end
      assert_equal 3, requests.size
      assert_equal [ "GET" ], requests.map(&:method).uniq
      assert_equal 2, delays.size
      assert_operator delays.first, :>=, 1
      assert_operator delays.last, :>=, 2
      assert options.all? { |option| option[:max_retries] == 0 && option[:open_timeout] == 5 }
      assert_equal 15_000, LocationApiBudget.status.fetch("reserved")
      assert_equal({ "geocoding" => 3 }, LocationApiBudget.status.fetch("requests"))
      assert_equal 1, LocationGeocodingResponse.count
    end
  end

  test "persistent timeouts stop after three attempts without caching a failure" do
    with_http(Array.new(3) { Net::ReadTimeout.new }) do |requests, delays|
      assert_raises(LocationNativeGeocoder::LookupError) do
        LocationNativeGeocoder.new(api_key: "synthetic-key").reverse(latitude: 44, longitude: -80)
      end
      assert_equal 3, requests.size
      assert_equal 2, delays.size
      assert_equal 0, LocationGeocodingResponse.count
    end
  end

  test "read-only nearby POST retries preserve its body and reserve the Nearby price" do
    with_http([ Errno::ECONNRESET.new, response("200", payload: { places: [] }) ]) do |requests|
      LocationApiBudget.with_repair_limit(cents: 7) do
        assert_nil LocationLandmarkLookup.new(api_key: "synthetic-key").geocode(latitude: 44, longitude: -80)
      end
      assert_equal [ "POST", "POST" ], requests.map(&:method)
      assert_equal requests.first.body, requests.last.body
      assert_equal 64_000, LocationApiBudget.status.fetch("reserved")
      assert_equal({ "places_nearby" => 2 }, LocationApiBudget.status.fetch("requests"))
    end
  end

  test "permission and quota failures stop immediately" do
    %w[400 403 429].each do |status|
      with_http([ response(status) ]) do |requests, delays|
        error = assert_raises(LocationNativeGeocoder::LookupError) do
          LocationNativeGeocoder.new(api_key: "synthetic-key").reverse(latitude: 44, longitude: -80)
        end
        assert_equal status.to_i, error.http_status
        assert_equal 1, requests.size
        assert_empty delays
      end
    end
  end

  test "a retry cannot exceed the existing spending ceiling" do
    with_http(Array.new(3) { Net::OpenTimeout.new }) do |requests|
      assert_raises(LocationApiBudget::Exceeded) do
        LocationApiBudget.with_repair_limit(cents: 1) do
          LocationNativeGeocoder.new(api_key: "synthetic-key").reverse(latitude: 44, longitude: -80)
        end
      end
      assert_equal 2, requests.size
      assert_equal 10_000, LocationApiBudget.status.fetch("reserved")
      assert_equal 0, LocationGeocodingResponse.count
    end
  end

  test "persistent server errors stop after three attempts" do
    with_http(Array.new(3) { response("503") }) do |requests|
      error = assert_raises(LocationNativeGeocoder::LookupError) do
        LocationNativeGeocoder.new(api_key: "synthetic-key").reverse(latitude: 44, longitude: -80)
      end
      assert_equal 503, error.http_status
      assert_equal 3, requests.size
    end
  end

  test "provider retry-after is honored and long waits stop without retrying early" do
    with_http([ response("503", retry_after: "6"), response("200") ]) do |requests, delays|
      LocationNativeGeocoder.new(api_key: "synthetic-key").reverse(latitude: 44, longitude: -80)
      assert_equal 2, requests.size
      assert_operator delays.sole, :>=, 6
    end
    LocationGeocodingResponse.delete_all
    with_http([ response("503", retry_after: 2.minutes.from_now.httpdate) ]) do |requests, delays|
      assert_raises(LocationNativeGeocoder::LookupError) do
        LocationNativeGeocoder.new(api_key: "synthetic-key").reverse(latitude: 44, longitude: -80)
      end
      assert_equal 1, requests.size
      assert_empty delays
    end
  end

  private

  def response(status, payload: { results: [] }, retry_after: nil)
    result = Net::HTTPResponse::CODE_TO_OBJ.fetch(status).new("1.1", status, "Synthetic response")
    result.instance_variable_set(:@read, true)
    result.body = payload.to_json
    result["Retry-After"] = retry_after if retry_after
    result
  end

  def with_http(outcomes)
    original = Net::HTTP.method(:start)
    original_sleep = LocationApiRequest.method(:sleep)
    requests, delays, options = [], [], []
    http = Object.new
    http.define_singleton_method(:request) do |request|
      requests << request
      outcome = outcomes.fetch(requests.size - 1)
      raise outcome if outcome.is_a?(Exception)

      outcome
    end
    Net::HTTP.define_singleton_method(:start) do |*_args, **keywords, &block|
      options << keywords
      block.call(http)
    end
    LocationApiRequest.define_singleton_method(:sleep) { |delay| delays << delay }
    yield requests, delays, options
  ensure
    Net::HTTP.define_singleton_method(:start, original)
    LocationApiRequest.define_singleton_method(:sleep, original_sleep)
  end
end
