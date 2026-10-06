module PhotoBookOrdersHelper
  PRODIGI_PROGRESS_STEPS = {
    "downloadAssets" => "Download artwork",
    "allocateProductionLocation" => "Choose printing lab",
    "printReadyAssetsPrepared" => "Prepare artwork for printing",
    "inProduction" => "Print book",
    "shipping" => "Ship book"
  }.freeze
  PRODIGI_ARTWORK_LABELS = { "default" => "Book PDF", "spine" => "Spine PDF" }.freeze

  def prodigi_status_label(value, fallback: "Not reported")
    value.is_a?(String) && value.present? ? value.titleize : fallback
  end

  def prodigi_tracking_url(value)
    return unless value.is_a?(String)

    uri = URI.parse(value)
    value if uri.is_a?(URI::HTTP) && uri.host.present? && uri.userinfo.nil?
  rescue URI::InvalidURIError
    nil
  end

  def prodigi_dispatch_time(value)
    Time.iso8601(value).in_time_zone if value.is_a?(String)
  rescue ArgumentError
    nil
  end

  def prodigi_shipping_description(method)
    case method
    when "Budget"
      "Economy delivery with slower transit. Tracking depends on the destination; US orders are tracked."
    when "Standard"
      "Regular delivery, faster than Budget. Tracking depends on the product and destination."
    when "StandardPlus"
      "An additional service offered by the printing lab. Prodigi does not specify a delivery window for this tier."
    when "Express"
      "Fast premium delivery, typically by tracked courier."
    when "Overnight"
      "Expected next working day after courier collection. Printing time is additional."
    end
  end
end
