class ProdigiBookQuote
  def initialize(order, client: ProdigiClient.new(environment: order.environment))
    @order = order
    @client = client
  end

  def call
    raise ProdigiClient::Error, "A confirmed order cannot be requoted." if @order.approved_at
    raise ProdigiClient::Error, "The PDF or its source photos are no longer available." unless @order.artwork_available?

    product = @client.product(@order.sku)
    validate_product!(product)
    prepare_spine!(product)
    item = @order.item.merge("attributes" => product.fetch("selectedAttributes"), "assets" => [ { "printArea" => "default", "pageCount" => @order.page_count } ] + (@spine_bytes ? [ { "printArea" => "spine" } ] : []))
    response = @client.quote({ "shippingMethod" => @order.shipping_method, "destinationCountryCode" => country,
      "currencyCode" => @order.currency, "items" => [ item ] })
    quote = Array(response["quotes"]).find { |candidate| candidate["shipmentMethod"] == @order.shipping_method }
    raise ProdigiClient::Error, "Prodigi has no quote for this shipping method and destination." unless quote

    %w[items shipping].each do |key|
      cost = quote.fetch("costSummary").fetch(key)
      amount = BigDecimal(cost.fetch("amount"))
      raise ProdigiClient::Error, "Prodigi returned an invalid price or currency." unless amount.finite? && amount >= 0 && cost.fetch("currency") == @order.currency
    end
    @order.with_lock do
      raise ProdigiClient::Error, "A confirmed order cannot be requoted." if @order.approved_at

      @order.spine_document.attach(io: StringIO.new(@spine_bytes), filename: "photobook-spine.pdf", content_type: "application/pdf") if @spine_bytes
      @order.update!(quote: quote.slice("shipmentMethod", "costSummary"), product: product, quoted_at: Time.current, status: "quoted", error: nil)
    end
  rescue KeyError, ArgumentError, TypeError
    raise ProdigiClient::Error, "Prodigi returned incomplete product or price information."
  end

  private

  def country
    @order.recipient.fetch("address").fetch("countryCode")
  end

  def validate_product!(product)
    raise ProdigiClient::Error, "Prodigi returned a different product." unless product.fetch("sku") == @order.sku && @order.sku.start_with?("BOOK-FE-")

    size = product.fetch("productDimensions")
    multiplier = { "mm" => 1.0, "cm" => 10.0, "in" => 25.4 }.fetch(size.fetch("units"))
    expected = PhotoBook::FORMATS.fetch(@order.photo_book_export.snapshot.fetch("format"))
    unless %w[width height].all? { |axis| (Float(size.fetch(axis)) * multiplier - expected.fetch(axis.to_sym)).abs < 1.0 }
      raise ProdigiClient::Error, "The configured Prodigi product does not match this PDF's page size."
    end
    areas = product.fetch("printAreas")
    # Layflat products also advertise an optional cover area. Our book PDF
    # already contains both covers; only unknown required areas must block it.
    supported_areas = areas.is_a?(Hash) && areas.key?("default") && areas.all? do |name, area|
      area.is_a?(Hash) && [ true, false ].include?(area["required"]) && (%w[default spine].include?(name) || area["required"] == false)
    end
    raise ProdigiClient::Error, "This product requires unsupported artwork. Choose a layflat photo book." unless supported_areas
    unless areas.key?("spine")
      raise ProdigiClient::Error, "This product does not accept the book's spine artwork."
    end
    variants = product.fetch("variants").select { |variant| variant.fetch("shipsTo").include?(country) }
    attributes = variants.map { |variant| variant.fetch("attributes") }.uniq
    raise ProdigiClient::Error, "This product does not ship to the selected country." if attributes.empty?
    raise ProdigiClient::Error, "This product has multiple finishes. Choose a product code with one finish." if attributes.size > 1

    product["selectedAttributes"] = attributes.first
  end

  def prepare_spine!(product)
    return unless product.fetch("printAreas").key?("spine")

    width = @client.spine({ "sku" => @order.sku, "destinationCountryCode" => country,
      "state" => @order.recipient.dig("address", "stateOrCounty"), "numberOfPages" => @order.page_count })
    @spine_bytes = ProdigiSpinePdf.new(@order.photo_book_export.snapshot, width_mm: width).render
  end
end
