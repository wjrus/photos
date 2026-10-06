require "test_helper"
require_relative "../support/prodigi_test_helper"

class ProdigiBookQuoteTest < ActiveSupport::TestCase
  include ProdigiTestHelper
  setup { configure_prodigi }
  teardown { restore_prodigi }

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
end
