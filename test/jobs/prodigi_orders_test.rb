require "test_helper"
require_relative "../support/prodigi_test_helper"

class ProdigiOrdersTest < ActiveSupport::TestCase
  include ProdigiTestHelper
  setup do
    configure_prodigi
    @book, @photo, export = ready_order_export
    @order = quoted_order(export)
  end
  teardown { restore_prodigi }

  test "approval binds price, address, environment and immutable PDF to an idempotent request" do
    assert_raises(ProdigiClient::Error) { @order.approve!(reviewed_quote: "stale-review") }
    @order.update!(quoted_at: 2.hours.ago)
    assert_raises(ProdigiClient::Error) { @order.approve!(reviewed_quote: @order.quote_digest) }
    @order.update!(quoted_at: Time.current)
    assert @order.approve!(reviewed_quote: @order.quote_digest)
    payload = @order.request_payload.deep_dup
    assert_equal @order.reference, payload["idempotencyKey"]
    assert_equal 2, payload["items"].first["assets"].size
    assert_equal 20, payload["items"].first["assets"].first["pageCount"]
    assert_not @order.approve!(reviewed_quote: nil)
    assert_equal payload, @order.reload.request_payload
    assert_raises(ActiveRecord::RecordInvalid) { @order.update!(copies: 2) }
    @book.update!(cover_title: "Later design")
    assert_equal payload, @order.reload.request_payload
  end

  test "live submission stays disabled even with a configured live key" do
    @order.update!(environment: "live")
    assert_raises(ProdigiClient::Error) { @order.approve!(reviewed_quote: @order.quote_digest) }
    assert_nil @order.reload.approved_at
  end

  test "timeout retry sends the identical body and completed jobs do not create another order" do
    @order.approve!(reviewed_quote: @order.quote_digest)
    requests = []
    response = remote_order(@order)
    client = Object.new
    client.define_singleton_method(:create_order) do |payload|
      requests << payload.deep_dup
      raise ProdigiClient::Error, "Synthetic timeout" if requests.size == 1
      response
    end
    with_prodigi_method(ProdigiClient, :new, client) do
      # call perform directly to observe the network failure before Active Job's retry handler.
      assert_raises(ProdigiClient::Error) { SubmitProdigiOrderJob.new.perform(@order) }
      assert_equal "submitting", @order.reload.status
      assert_enqueued_with(job: RefreshProdigiOrderJob) { SubmitProdigiOrderJob.new.perform(@order) }
      SubmitProdigiOrderJob.new.perform(@order)
    end
    assert_equal 2, requests.size
    assert_equal requests.first, requests.last
    assert_equal "ord_synthetic_123", @order.reload.remote_id
    assert_not @order.remote_status.key?("recipient")
  end

  test "removed sources or expired artwork access prevent new submissions" do
    @order.approve!(reviewed_quote: @order.quote_digest)
    @photo.update!(restricted: true)
    assert_raises(ProdigiClient::Error) { SubmitProdigiOrderJob.new.perform(@order) }
    assert_nil @order.reload.remote_id
    @photo.update!(restricted: false)
    travel_to 31.days.from_now do
      assert_raises(ProdigiClient::Error) { SubmitProdigiOrderJob.new.perform(@order) }
    end
  end

  test "rejected requests preserve the frozen order and error without automatic retries" do
    @order.approve!(reviewed_quote: @order.quote_digest)
    payload = @order.request_payload.deep_dup
    client = Object.new
    requests = []
    client.define_singleton_method(:create_order) do |body|
      requests << body.deep_dup
      raise ProdigiClient::RequestError, "Prodigi rejected the order submission (HTTP 400)."
    end
    with_prodigi_method(ProdigiClient, :new, client) do
      assert_no_enqueued_jobs(only: SubmitProdigiOrderJob) { SubmitProdigiOrderJob.perform_now(@order) }
    end
    assert_equal [ payload ], requests
    assert_equal payload, @order.reload.request_payload
    assert_equal "submitting", @order.status
    assert_nil @order.remote_id
    assert_includes @order.error, "HTTP 400"
  end

  test "authenticated refresh ignores older status and rejects a different remote order" do
    @order.approve!(reviewed_quote: @order.quote_digest)
    @order.record_remote!(remote_order(@order, stage: "Complete"))
    @order.record_remote!(remote_order(@order, stage: "InProgress", updated: 1.hour.ago.iso8601))
    assert_equal "Complete", @order.reload.remote_status["stage"]
    assert_raises(ProdigiClient::Error) { @order.record_remote!(remote_order(@order).merge("id" => "ord_other")) }
  end

  test "artwork progress retains only file areas and states without copying private asset URLs" do
    @order.approve!(reviewed_quote: @order.quote_digest)
    data = remote_order(@order).merge("items" => [ { "assets" => [
      { "printArea" => "default", "status" => "Complete", "url" => "PRIVATE_SYNTHETIC_URL", "thumbnailUrl" => "PRIVATE_SYNTHETIC_THUMBNAIL" },
      { "printArea" => "spine", "status" => "InProgress", "url" => "PRIVATE_SYNTHETIC_URL" },
      { "printArea" => "unknown", "status" => "Complete", "url" => "PRIVATE_SYNTHETIC_URL" } ] } ])
    @order.record_remote!(data)
    assert_equal [ { "printArea" => "default", "status" => "Complete" }, { "printArea" => "spine", "status" => "InProgress" } ], @order.remote_status["assets"]
    assert_not_includes @order.remote_status.to_json, "PRIVATE_SYNTHETIC"
  end
end
