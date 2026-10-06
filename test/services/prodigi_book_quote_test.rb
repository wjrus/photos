require "test_helper"
require_relative "../support/prodigi_test_helper"

class ProdigiBookQuoteTest < ActiveSupport::TestCase
  include ProdigiTestHelper
  setup { configure_prodigi }
  teardown { restore_prodigi }

  test "all available methods are quoted once then selected locally with their own book and shipping prices" do
    _, _, export = ready_order_export
    order = draft_order(export)
    client = quote_client(quote: synthetic_shipping_quotes)
    ProdigiBookQuote.new(order, client: client).call
    digest = order.quote_digest
    order.reload
    assert_equal digest, order.quote_digest
    assert_equal %w[Budget Express], order.shipping_options.map { |option| option["shipmentMethod"] }
    assert_not order.shipping_selected?
    assert_raises(ProdigiClient::Error) { order.approve!(reviewed_quote: digest) }
    order.select_shipping!(method: "Express", reviewed_quote: digest)
    assert_equal BigDecimal("56.70"), order.quote_total
    assert_equal [ { "name" => "Example Courier", "service" => "Tracked service" } ], order.quote["carriers"]
    assert_equal %i[product spine quote], client.calls
    assert_equal order.quote_digest, order.reload.quote_digest
    assert_raises(ProdigiClient::Error) { order.approve!(reviewed_quote: digest) }
    order.approve!(reviewed_quote: order.quote_digest)
    assert_equal "Express", order.request_payload["shippingMethod"]
  end

  test "unavailable expired stale and confirmed shipping selections cannot change the order" do
    _, _, export = ready_order_export
    order = quoted_order(export)
    original = order.quote.deep_dup
    assert_raises(ProdigiClient::Error) { order.select_shipping!(method: "Overnight", reviewed_quote: order.quote_digest) }
    assert_raises(ProdigiClient::Error) { order.select_shipping!(method: "Budget", reviewed_quote: "stale") }
    order.update!(quoted_at: 2.hours.ago)
    assert_raises(ProdigiClient::Error) { order.select_shipping!(method: "Budget", reviewed_quote: order.quote_digest) }
    assert_equal original, order.reload.quote
    order.update!(quoted_at: Time.current)
    order.approve!(reviewed_quote: order.quote_digest)
    assert_raises(ProdigiClient::Error) { order.select_shipping!(method: "Budget", reviewed_quote: order.quote_digest) }
    assert_equal original, order.reload.quote
  end

  test "refresh retains an available selection and requires a new choice when it disappears" do
    _, _, export = ready_order_export
    order = quoted_order(export)
    client = quote_client(quote: synthetic_shipping_quotes)
    ProdigiBookQuote.new(order, client: client).call
    assert order.shipping_selected?
    order.select_shipping!(method: "Express", reviewed_quote: order.quote_digest)
    ProdigiBookQuote.new(order, client: quote_client).call
    assert_equal "Budget", order.shipping_method
    assert_not order.shipping_selected?
    assert_raises(ProdigiClient::Error) { order.approve!(reviewed_quote: order.quote_digest) }
  end

  test "malformed or ambiguous alternate prices block the whole quote" do
    _, _, export = ready_order_export
    [ "NaN", "-1.00" ].each do |amount|
      response = synthetic_shipping_quotes
      response["quotes"].first["costSummary"]["shipping"]["amount"] = amount
      order = draft_order(export)
      assert_raises(ProdigiClient::Error) { ProdigiBookQuote.new(order, client: quote_client(quote: response)).call }
      assert_empty order.reload.quote
    end
    response = synthetic_quote
    response["quotes"] *= 2
    assert_raises(ProdigiClient::Error) { ProdigiBookQuote.new(draft_order(export), client: quote_client(quote: response)).call }
    assert_raises(ProdigiClient::Error) { ProdigiBookQuote.new(draft_order(export), client: quote_client(quote: { "quotes" => [] })).call }
  end

  test "shipping method casing is normalized and older single method quotes remain usable" do
    _, _, export = ready_order_export
    order = draft_order(export)
    response = synthetic_shipping_quotes
    response["quotes"].first["shipmentMethod"] = "express"
    ProdigiBookQuote.new(order, client: quote_client(quote: response)).call
    assert_equal %w[Budget Express], order.shipping_options.map { |quote| quote["shipmentMethod"] }
    order.update!(quote: synthetic_quote["quotes"].first)
    assert order.shipping_selected?
    assert_equal [ order.quote ], order.shipping_options
    order.approve!(reviewed_quote: order.quote_digest)
    assert_equal "Budget", order.request_payload["shippingMethod"]
  end

  test "a concurrent shipping selection is not overwritten by a quote refresh" do
    _, _, export = ready_order_export
    order = quoted_order(export)
    ProdigiBookQuote.new(order, client: quote_client(quote: synthetic_shipping_quotes)).call
    response = synthetic_shipping_quotes
    client = quote_client
    client.define_singleton_method(:quote) do |_payload|
      PhotoBookOrder.find(order.id).select_shipping!(method: "Express", reviewed_quote: order.quote_digest)
      response
    end
    assert_raises(ProdigiClient::Error) { ProdigiBookQuote.new(order, client: client).call }
    assert_equal "Express", order.reload.shipping_method
    assert_equal BigDecimal("56.70"), order.quote_total
  end

  test "quote includes both covers and separate spine artwork without sharing an address or PDF URL" do
    book, _, export = ready_order_export
    order = quoted_order(export)
    assert_equal BigDecimal("46.70"), order.quote_total
    assert order.quote_current?
    assert order.request_payload.empty?
    assert order.remote_id.nil?
    bytes = order.spine_document.download
    assert bytes.start_with?("%PDF-")
    assert_includes bytes, "/FontFile2"
    box = bytes.match(/\/MediaBox\s+\[([^\]]+)\]/)[1].split.map(&:to_f)
    assert_in_delta 8 * 72 / 25.4, box[2], 0.01
    assert_in_delta 210 * 72 / 25.4, box[3], 0.01
    assert_equal "Synthetic journeys · Été", export.snapshot["spine_text"]
    assert_equal({ "cover" => { "required" => false }, "default" => { "required" => true }, "spine" => { "required" => false } }, order.product["printAreas"])
    assert_equal %w[default spine], order.item.fetch("assets").map { |asset| asset.fetch("printArea") }
    assert_not book.destroy
  end

  test "unknown artwork areas must be explicitly optional before they can be omitted" do
    _, _, export = ready_order_export
    [ true, nil, "false" ].each do |required|
      product = synthetic_product.deep_merge("printAreas" => { "extra" => { "required" => required } })
      client = quote_client(product: product)
      order = draft_order(export)
      assert_raises(ProdigiClient::Error) { ProdigiBookQuote.new(order, client: client).call }
      assert_equal [ :product ], client.calls
      assert_nil order.reload.quoted_at
    end
  end

  test "the spine template is never silently omitted when the book name is the label" do
    _, _, export = ready_order_export
    export.snapshot["spine_text"] = ""
    export.save!
    product = synthetic_product
    product.fetch("printAreas").delete("spine")
    client = quote_client(product: product)
    error = assert_raises(ProdigiClient::Error) { ProdigiBookQuote.new(draft_order(export), client: client).call }
    assert_includes error.message, "spine artwork"
    assert_equal [ :product ], client.calls
  end

  test "product dimensions, destination, unsupported areas and multiple finishes block quoting" do
    _, _, export = ready_order_export
    order = draft_order(export)
    [ synthetic_product.deep_merge("productDimensions" => { "width" => 297 }),
      synthetic_product.deep_merge("printAreas" => { "other" => { "required" => true } }),
      synthetic_product.merge("variants" => [ { "attributes" => {}, "shipsTo" => [ "GB" ] } ]),
      synthetic_product.merge("variants" => [ { "attributes" => {}, "shipsTo" => [ "US" ] }, { "attributes" => { "finish" => "matte" }, "shipsTo" => [ "US" ] } ]) ].each do |product|
      client = quote_client(product: product)
      assert_raises(ProdigiClient::Error) { ProdigiBookQuote.new(order.reload, client: client).call }
      assert_nil order.reload.quoted_at
      assert_equal [ :product ], client.calls
    end
  end

  test "unknown currencies or nonfinite prices do not become confirmable quotes" do
    _, _, export = ready_order_export
    [ "NaN", "-1.00", "Infinity" ].each do |amount|
      order = draft_order(export)
      client = quote_client(quote: synthetic_quote(amount: amount))
      assert_raises(ProdigiClient::Error) { ProdigiBookQuote.new(order, client: client).call }
      assert_nil order.reload.quoted_at
    end
    order = draft_order(export)
    quote = synthetic_quote
    quote["quotes"].first["costSummary"]["shipping"]["currency"] = "GBP"
    assert_raises(ProdigiClient::Error) { ProdigiBookQuote.new(order, client: quote_client(quote: quote)).call }
  end

  test "unsupported spine glyphs fail before quote or submission" do
    _, _, export = ready_order_export
    export.snapshot["spine_text"] = "Unsupported 🚀"
    export.save!
    client = quote_client
    error = assert_raises(ProdigiClient::Error) { ProdigiBookQuote.new(draft_order(export), client: client).call }
    assert_includes error.message, "unsupported"
    assert_equal %i[product spine], client.calls
  end

  test "quote cannot replace artwork after a concurrent approval" do
    _, _, export = ready_order_export
    order = quoted_order(export)
    attachment_id = order.spine_document.id
    # Approval during the remote quote call must win over its later result.
    client = Object.new
    product = synthetic_product
    quote = synthetic_quote
    client.define_singleton_method(:product) { |_sku| product }
    client.define_singleton_method(:spine) { |_payload| 9.0 }
    client.define_singleton_method(:quote) do |_payload|
      PhotoBookOrder.find(order.id).approve!(reviewed_quote: order.quote_digest)
      quote
    end
    assert_raises(ProdigiClient::Error) { ProdigiBookQuote.new(order, client: client).call }
    assert_equal attachment_id, order.reload.spine_document.id
    assert_equal "submitting", order.status
  end

  test "a concurrent delivery or copy edit cannot receive the previous inputs' price" do
    _, _, export = ready_order_export
    order = draft_order(export)
    client = quote_client
    quote = synthetic_quote
    client.define_singleton_method(:quote) do |_payload|
      PhotoBookOrder.find(order.id).update!(copies: 2)
      quote
    end
    error = assert_raises(ProdigiClient::Error) { ProdigiBookQuote.new(order, client: client).call }
    assert_includes error.message, "Order details changed"
    assert_equal 2, order.reload.copies
    assert_nil order.quoted_at
    assert_not order.spine_document.attached?
  end
end
