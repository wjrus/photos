require "test_helper"
require_relative "../support/prodigi_test_helper"

class ProdigiClientTest < ActiveSupport::TestCase
  include ProdigiTestHelper
  setup { configure_prodigi }
  teardown { restore_prodigi }

  test "HTTP requests use fixed environment hosts, authentication, JSON and bounded timeouts" do
    captured = []
    response = Net::HTTPOK.new("1.1", "200", "OK")
    response.define_singleton_method(:body) { { outcome: "Created", order: { id: "ord_synthetic" } }.to_json }
    http = Object.new
    http.define_singleton_method(:request) { |request| captured << request; response }
    start = lambda do |host, port, **options, &block|
      assert_equal "api.sandbox.prodigi.com", host
      assert_equal 443, port
      assert_equal({ use_ssl: true, open_timeout: 5, read_timeout: 20, write_timeout: 20 }, options)
      block.call(http)
    end
    with_prodigi_method(Net::HTTP, :start, start) { ProdigiClient.new.create_order({ "idempotencyKey" => "synthetic" }) }
    request = captured.first
    assert_equal "/v4.0/orders", request.path
    assert_equal CONFIGURATION.fetch("PRODIGI_SANDBOX_API_KEY"), request["X-API-Key"]
    assert_equal "application/json", request["Content-Type"]
    assert_equal({ "idempotencyKey" => "synthetic" }, JSON.parse(request.body))
  end

  test "API response bodies do not leak through errors and invalid identifiers cannot change request hosts" do
    http = Object.new
    response = Net::HTTPBadRequest.new("1.1", "400", "Bad Request")
    response.define_singleton_method(:body) { "sensitive synthetic address or key" }
    http.define_singleton_method(:request) { |_request| response }
    start = ->(*_args, **_options, &block) { block.call(http) }
    with_prodigi_method(Net::HTTP, :start, start) do
      error = assert_raises(ProdigiClient::Error) { ProdigiClient.new.create_order({}) }
      assert_not_includes error.message, "sensitive"
    end
    assert_raises(ProdigiClient::Error) { ProdigiClient.new.order("https://example.invalid/") }
    assert_raises(ProdigiClient::Error) { ProdigiClient.new.product("../orders") }
    assert_raises(ProdigiClient::Error) { ProdigiClient.new(environment: "unknown") }
  end

  test "catalogue square SKUs with underscores reach the product endpoint" do
    requested = []
    response = Net::HTTPOK.new("1.1", "200", "OK")
    response.define_singleton_method(:body) { { outcome: "Ok", product: { sku: "BOOK-FE-8_3-SQ-LF-G" } }.to_json }
    http = Object.new
    http.define_singleton_method(:request) { |request| requested << request.path; response }
    start = ->(*_args, **_options, &block) { block.call(http) }
    with_prodigi_method(Net::HTTP, :start, start) do
      %w[BOOK-FE-8_3-SQ-LF-G BOOK-FE-11_7-SQ-LF-G].each { |sku| ProdigiClient.new.product(sku) }
    end
    assert_equal %w[/v4.0/products/BOOK-FE-8_3-SQ-LF-G /v4.0/products/BOOK-FE-11_7-SQ-LF-G], requested
  end

  test "sandbox diagnostics expose artwork requirements and omit private request and response fields" do
    output = StringIO.new
    logger = ActiveSupport::Logger.new(output)
    private_value = "PRIVATE_SYNTHETIC_VALUE"
    result = { "outcome" => "Ok", "product" => synthetic_product.merge("description" => private_value),
      "quotes" => synthetic_quote["quotes"], "order" => { "id" => "ord_synthetic", "recipient" => private_value,
        "assets" => private_value, "status" => { "stage" => "InProgress", "issues" => private_value } }, "message" => private_value }
    response = Net::HTTPOK.new("1.1", "200", "OK")
    response.define_singleton_method(:body) { result.to_json }
    http = Object.new
    http.define_singleton_method(:request) { |_request| response }
    start = ->(*_args, **_options, &block) { block.call(http) }
    payload = { "recipient" => private_value, "callbackUrl" => private_value, "metadata" => private_value,
      "items" => [ { "sku" => "BOOK-FE-A4-L-LF-G", "copies" => 1,
        "assets" => [ { "printArea" => "default", "pageCount" => 24, "url" => private_value } ] } ] }
    with_prodigi_method(Rails, :logger, logger) do
      with_prodigi_method(Net::HTTP, :start, start) { ProdigiClient.new.create_order(payload) }
    end
    assert_includes output.string, '"printAreas":{"cover":{"required":false},"default":{"required":true},"spine":{"required":false}}'
    assert_includes output.string, '"pageCount":24'
    assert_includes output.string, '"http_status":"200"'
    assert_not_includes output.string, private_value
    assert_not_includes output.string, CONFIGURATION.fetch("PRODIGI_SANDBOX_API_KEY")

    output.truncate(0)
    output.rewind
    with_prodigi_method(Rails, :logger, logger) do
      with_prodigi_method(Net::HTTP, :start, start) { ProdigiClient.new(environment: "live").create_order(payload) }
    end
    assert_empty output.string
  end

  test "failed sandbox responses log only HTTP metadata without vendor error bodies" do
    output = StringIO.new
    logger = ActiveSupport::Logger.new(output)
    response = Net::HTTPBadRequest.new("1.1", "400", "Bad Request")
    response.define_singleton_method(:body) { "PRIVATE_SYNTHETIC_ERROR_BODY" }
    http = Object.new
    http.define_singleton_method(:request) { |_request| response }
    start = ->(*_args, **_options, &block) { block.call(http) }
    with_prodigi_method(Rails, :logger, logger) do
      with_prodigi_method(Net::HTTP, :start, start) do
        assert_raises(ProdigiClient::Error) { ProdigiClient.new.create_order({}) }
      end
    end
    assert_includes output.string, '"http_status":"400"'
    assert_not_includes output.string, "PRIVATE_SYNTHETIC_ERROR_BODY"
  end

  test "validation errors identify the operation safe fields and support trace without leaking values" do
    output = StringIO.new
    logger = ActiveSupport::Logger.new(output)
    trace = "00-0123456789abcdef0123456789abcdef-0123456789abcdef-00"
    body = { "statusText" => "PRIVATE_SYNTHETIC_MESSAGE", "traceParent" => trace,
      "data" => { "errors" => { "recipient.email" => [ "PRIVATE_SYNTHETIC_EMAIL" ],
        "items[0].assets[0].pageCount" => [ "PRIVATE_SYNTHETIC_URL" ],
        "PRIVATE_SYNTHETIC_KEY" => [ "PRIVATE_SYNTHETIC_SECRET" ] } } }
    response = Net::HTTPBadRequest.new("1.1", "400", "Bad Request")
    response.define_singleton_method(:body) { body.to_json }
    http = Object.new
    http.define_singleton_method(:request) { |_request| response }
    start = ->(*_args, **_options, &block) { block.call(http) }
    with_prodigi_method(Rails, :logger, logger) do
      with_prodigi_method(Net::HTTP, :start, start) do
        error = assert_raises(ProdigiClient::RequestError) { ProdigiClient.new.create_order({}) }
        assert_includes error.message, "order submission (HTTP 400)"
        assert_includes error.message, "recipient.email"
        assert_includes error.message, "items[0].assets[0].pageCount"
        assert_includes error.message, trace
        assert_not_includes error.message, "account configuration"
        assert_not_includes error.message, "PRIVATE_SYNTHETIC"
      end
    end
    assert_includes output.string, '"event":"response_error"'
    assert_includes output.string, trace
    assert_not_includes output.string, "PRIVATE_SYNTHETIC"
  end

  test "Prodigi failures with numbered address fields are identified without exposing descriptions" do
    body = { "outcome" => "ValidationFailed", "failures" => {
      "recipient.address.line2" => [ { "code" => "MustNotBeEmpty", "description" => "PRIVATE_SYNTHETIC_VALUE" } ] } }
    response = Net::HTTPBadRequest.new("1.1", "400", "Bad Request")
    response.define_singleton_method(:body) { body.to_json }
    http = Object.new
    http.define_singleton_method(:request) { |_request| response }
    start = ->(*_args, **_options, &block) { block.call(http) }
    with_prodigi_method(Net::HTTP, :start, start) do
      error = assert_raises(ProdigiClient::RequestError) { ProdigiClient.new.create_order({}) }
      assert_includes error.message, "recipient.address.line2"
      assert_not_includes error.message, "PRIVATE_SYNTHETIC_VALUE"
    end
  end

  test "submission omits blank optional recipient fields and serializes identical retries without changing the approved payload" do
    payload = { "idempotencyKey" => "synthetic-reference", "recipient" => synthetic_recipient.deep_merge(
      "email" => "", "phoneNumber" => "", "address" => { "line2" => "" }) }
    original = payload.deep_dup
    requests = []
    response = Net::HTTPOK.new("1.1", "200", "OK")
    response.define_singleton_method(:body) { { "outcome" => "Created", "order" => { "id" => "ord_synthetic" } }.to_json }
    http = Object.new
    http.define_singleton_method(:request) { |request| requests << request.body; response }
    start = ->(*_args, **_options, &block) { block.call(http) }
    with_prodigi_method(Net::HTTP, :start, start) do
      2.times { ProdigiClient.new.create_order(payload) }
      submitted = JSON.parse(requests.first)
      assert_equal original, payload
      assert_equal requests.first, requests.second
      assert_equal original["idempotencyKey"], submitted["idempotencyKey"]
      assert_equal original.dig("recipient", "name"), submitted.dig("recipient", "name")
      assert_equal original.dig("recipient", "address").except("line2"), submitted.dig("recipient", "address")
      assert_not submitted.fetch("recipient").key?("email")
      assert_not submitted.fetch("recipient").key?("phoneNumber")
      payload["recipient"] = synthetic_recipient.deep_merge("phoneNumber" => "+15555550100", "address" => { "line2" => "Unit Example" })
      ProdigiClient.new.create_order(payload)
      assert_equal payload, JSON.parse(requests.last)
      payload["recipient"]["address"]["countryCode"] = "GB"
      payload["recipient"]["address"]["stateOrCounty"] = ""
      ProdigiClient.new.create_order(payload)
      assert_not JSON.parse(requests.last).dig("recipient", "address").key?("stateOrCounty")
    end
  end

  test "transient HTTP errors remain retryable and malformed bodies cannot leak through support traces" do
    response = Net::HTTPTooManyRequests.new("1.1", "429", "Too Many Requests")
    response["traceParent"] = "PRIVATE_SYNTHETIC_TRACE"
    response.define_singleton_method(:body) { "PRIVATE_SYNTHETIC_BODY" }
    http = Object.new
    http.define_singleton_method(:request) { |_request| response }
    start = ->(*_args, **_options, &block) { block.call(http) }
    with_prodigi_method(Net::HTTP, :start, start) do
      error = assert_raises(ProdigiClient::Error) { ProdigiClient.new.quote({}) }
      assert_not error.is_a?(ProdigiClient::RequestError)
      assert_includes error.message, "price quote (HTTP 429)"
      assert_not_includes error.message, "PRIVATE_SYNTHETIC"
    end
  end
end
