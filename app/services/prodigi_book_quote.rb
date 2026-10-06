class ProdigiBookQuote
  def initialize(order, client: ProdigiClient.new(environment: order.environment))
    @order = order
    @client = client
  end

  def call
    raise ProdigiClient::Error, "A confirmed order cannot be requoted." if @order.approved_at
    raise ProdigiClient::Error, "The PDF or its source photos are no longer available." unless @order.artwork_available?

    quoted_inputs = @order.attributes.slice("photo_book_export_id", "environment", "sku", "copies", "shipping_method", "currency", "recipient").deep_dup
    previous_quote = @order.quote.deep_dup
    previously_selected = @order.shipping_selected?
    product = @client.product(@order.sku)
    validate_product!(product)
    prepare_spine!(product)
    item = @order.item.merge("attributes" => product.fetch("selectedAttributes"), "assets" => [ { "printArea" => "default", "pageCount" => @order.page_count } ] + (@spine_bytes ? [ { "printArea" => "spine" } ] : []))
    response = @client.quote({ "destinationCountryCode" => country,
      "currencyCode" => @order.currency, "items" => [ item ] })
    options = shipping_options(response)
    quote = options.find { |candidate| candidate["shipmentMethod"] == @order.shipping_method }
    selected = previously_selected && quote.present?
    quote ||= options.first
    @order.with_lock do
      raise ProdigiClient::Error, "A confirmed order cannot be requoted." if @order.approved_at
      unless @order.attributes.slice(*quoted_inputs.keys) == quoted_inputs && @order.quote == previous_quote
        raise ProdigiClient::Error, "Order details changed while fetching the price. Get a new quote."
      end

      @order.spine_document.attach(io: StringIO.new(@spine_bytes), filename: "photobook-spine.pdf", content_type: "application/pdf") if @spine_bytes
      @order.update!(shipping_method: quote.fetch("shipmentMethod"), quote: quote.merge("shippingOptions" => options, "shippingSelected" => selected),
        product: product, quoted_at: Time.current, status: "quoted", error: nil)
    end
  rescue KeyError, ArgumentError, TypeError
    raise ProdigiClient::Error, "Prodigi returned incomplete product or price information."
  end

  private

  def shipping_options(response)
    options = Array(response["quotes"]).filter_map do |quote|
      method = PhotoBookOrder::SHIPPING_METHODS.find { |name| name.casecmp?(quote.fetch("shipmentMethod")) }
      next unless method

      costs = %w[items shipping].index_with do |key|
        cost = quote.fetch("costSummary").fetch(key)
        amount = BigDecimal(cost.fetch("amount"))
        unless amount.finite? && amount >= 0 && cost.fetch("currency") == @order.currency
          raise ProdigiClient::Error, "Prodigi returned an invalid price or currency."
        end
        cost.slice("amount", "currency")
      end
      carriers = Array(quote["shipments"]).filter_map do |shipment|
        carrier = shipment["carrier"]
        next unless carrier.is_a?(Hash)

        carrier.slice("name", "service").transform_values { |value| value.to_s.truncate(200) }
      end.uniq
      { "shipmentMethod" => method, "costSummary" => costs, "carriers" => carriers }
    end
    if options.empty?
      raise ProdigiClient::Error, "Prodigi has no shipping quote for this book and destination."
    end
    unless options.map { |quote| quote.fetch("shipmentMethod") }.uniq.size == options.size
      raise ProdigiClient::Error, "Prodigi returned ambiguous shipping prices. Refresh the quote."
    end
    options.sort_by { |quote| PhotoBookOrder::SHIPPING_METHODS.index(quote.fetch("shipmentMethod")) }
  end

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
