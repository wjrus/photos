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
