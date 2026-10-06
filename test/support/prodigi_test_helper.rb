require_relative "photo_book_test_helper"

module ProdigiTestHelper
  include PhotoBookTestHelper
  CONFIGURATION = {
    "PHOTOS_HOST" => "photos.example.invalid",
    "PRODIGI_ENVIRONMENT" => "sandbox", "PRODIGI_SANDBOX_API_KEY" => "synthetic-sandbox-key",
    "PRODIGI_LIVE_API_KEY" => "synthetic-live-key", "PRODIGI_LIVE_ORDERING_ENABLED" => "false",
    "PRODIGI_PUBLIC_BASE_URL" => "https://photos.example.invalid", "PRODIGI_WEBHOOK_SECRET" => "synthetic-webhook-secret-32-characters",
    "PRODIGI_SKU_LANDSCAPE_A4" => nil, "PRODIGI_SKU_SQUARE_210" => "BOOK-FE-SYNTHETIC-LF-G",
    "PRODIGI_SKU_SQUARE_297" => nil
  }.freeze

  def configure_prodigi
    @previous_prodigi = CONFIGURATION.keys.index_with { |key| ENV[key] }
    CONFIGURATION.each { |key, value| ENV[key] = value }
  end

  def restore_prodigi
    @previous_prodigi.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  def ready_order_export
    book, photo = book_with_photo(print_ready: true)
    book.update!(spine_text: "Synthetic journeys · Été")
    export = pending_book_export(book)
    export.document.attach(io: StringIO.new("%PDF-1.4\nSynthetic test artwork"), filename: export.filename, content_type: "application/pdf")
    export.update!(status: "ready", processed_pages: 20)
    [ book, photo, export ]
  end

  def synthetic_recipient
    { "name" => "Synthetic Recipient", "email" => "recipient@example.invalid",
      "address" => { "line1" => "123 Example Street", "townOrCity" => "Example City", "postalOrZipCode" => "00000", "countryCode" => "US", "stateOrCounty" => "CA" } }
  end

  def draft_order(export)
    export.orders.create!(environment: "sandbox", sku: CONFIGURATION.fetch("PRODIGI_SKU_SQUARE_210"), recipient: synthetic_recipient)
  end

  def synthetic_product
    { "sku" => CONFIGURATION.fetch("PRODIGI_SKU_SQUARE_210"), "productDimensions" => { "width" => 210, "height" => 210, "units" => "mm" },
      "printAreas" => { "cover" => { "required" => false }, "default" => { "required" => true }, "spine" => { "required" => false } },
      "variants" => [ { "attributes" => {}, "shipsTo" => [ "US", "GB" ] } ] }
  end

  def synthetic_quote(amount: "38.20")
    { "outcome" => "Created", "quotes" => [ { "shipmentMethod" => "Budget", "costSummary" => {
      "items" => { "amount" => amount, "currency" => "USD" }, "shipping" => { "amount" => "8.50", "currency" => "USD" } } } ] }
  end

  def quote_client(product: synthetic_product, quote: synthetic_quote)
    test = self
    calls = []
    client = Object.new
    client.define_singleton_method(:calls) { calls }
    client.define_singleton_method(:product) do |sku|
      calls << :product
      test.assert_equal CONFIGURATION.fetch("PRODIGI_SKU_SQUARE_210"), sku
      product.deep_dup
    end
    client.define_singleton_method(:spine) do |payload|
      calls << :spine
      test.assert_equal 20, payload["numberOfPages"]
      test.assert_equal "CA", payload["state"]
      8.0
    end
    client.define_singleton_method(:quote) do |payload|
      calls << :quote
      test.assert_equal [ { "printArea" => "default", "pageCount" => 20 }, { "printArea" => "spine" } ], payload["items"].first["assets"]
      test.assert_not payload.key?("recipient")
      test.assert_not payload.to_json.include?("https://")
      quote.deep_dup
    end
    client
  end

  def with_prodigi_method(target, name, replacement)
    original = target.method(name)
    target.define_singleton_method(name) do |*args, **options, &block|
      replacement.respond_to?(:call) ? replacement.call(*args, **options, &block) : replacement
    end
    yield
  ensure
    target.define_singleton_method(name, original)
  end

  def quoted_order(export)
    order = draft_order(export)
    client = quote_client
    ProdigiBookQuote.new(order, client: client).call
    assert_equal %i[product spine quote], client.calls
    order.reload
  end

  def remote_order(order, stage: "InProgress", updated: Time.current.iso8601(6))
    { "id" => "ord_synthetic_123", "merchantReference" => order.reference, "lastUpdated" => updated,
      "status" => { "stage" => stage, "issues" => [] }, "shipments" => [], "recipient" => synthetic_recipient }
  end
end
