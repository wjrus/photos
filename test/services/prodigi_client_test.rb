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
end
