require "prawn"

class ProdigiSpinePdf
  def initialize(snapshot, width_mm:)
    @snapshot = snapshot
    @width = width_mm
  end

  def render
    raise ProdigiClient::Error, "Prodigi returned an invalid spine width." unless @width.finite? && @width.between?(2, 80)

    height = PhotoBook::FORMATS.fetch(@snapshot.fetch("format")).fetch(:height) * PhotoBookLayout::POINTS_PER_MM
    width = @width * PhotoBookLayout::POINTS_PER_MM
    pdf = Prawn::Document.new(page_size: [ width, height ], margin: 0, compress: true)
    pdf.fill_color(@snapshot.fetch("background_color").delete_prefix("#"))
    pdf.fill_rectangle([ 0, height ], width, height)
    pdf.font(PhotoBookTypography.font_path("sans").to_s)
    cmap = TTFunk::File.open(PhotoBookTypography.font_path("sans").to_s).cmap.unicode.first
    unless @snapshot.fetch("spine_text", "").codepoints.all? { |codepoint| cmap[codepoint].to_i.positive? }
      raise ProdigiClient::Error, "The spine label contains unsupported symbols or emoji. Edit it and generate a new book PDF."
    end
    pdf.fill_color(@snapshot.fetch("text_color").delete_prefix("#"))
    margin = [ 2 * PhotoBookLayout::POINTS_PER_MM, width / 4 ].min
    # Rotate a horizontal text box onto the narrow vertical spine. The font is
    # embedded and shrinks to fit, rather than clipping a long spine label.
    pdf.rotate(90, origin: [ width / 2, height / 2 ]) do
      overflow = pdf.text_box(@snapshot.fetch("spine_text", ""), at: [ width / 2 - height / 2 + 10 * PhotoBookLayout::POINTS_PER_MM, height / 2 + width / 2 - margin ],
        width: height - 20 * PhotoBookLayout::POINTS_PER_MM, height: width - 2 * margin, size: [ 12, width / 2 ].min,
        align: :center, valign: :center, overflow: :shrink_to_fit, min_font_size: 2)
      raise ProdigiClient::Error, "The spine label does not fit. Shorten it before generating another PDF." if overflow.present?
    end
    pdf.render
  end
end
