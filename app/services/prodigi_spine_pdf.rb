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
    title = (@snapshot["spine_text"].presence || @snapshot.fetch("title")).squish
    cmap = TTFunk::File.open(PhotoBookTypography.font_path("sans").to_s).cmap.unicode.first
    unless title.codepoints.all? { |codepoint| cmap[codepoint].to_i.positive? }
      raise ProdigiClient::Error, "The spine label contains unsupported symbols or emoji. Edit it and generate a new book PDF."
    end
    pdf.fill_color(@snapshot.fetch("text_color").delete_prefix("#"))
    margin = [ 2 * PhotoBookLayout::POINTS_PER_MM, width / 4 ].min
    end_margin = 10 * PhotoBookLayout::POINTS_PER_MM
    length = height - 2 * end_margin
    brand_width = [ 40 * PhotoBookLayout::POINTS_PER_MM, length / 4 ].min
    gap = 10 * PhotoBookLayout::POINTS_PER_MM
    x = width / 2 - height / 2 + end_margin
    y = height / 2 + width / 2 - margin
    # Keep the brand at the bottom and the title at the top. Each label is
    # flipped within its box below so both read from top to bottom.
    pdf.rotate(90, origin: [ width / 2, height / 2 ]) do
      draw_label(pdf, "wjr photos", font: "lato", at: [ x, y ], width: brand_width, height: width - 2 * margin, size: [ 9, width / 2 ].min, align: :left)
      draw_label(pdf, title, font: "sans", at: [ x + brand_width + gap, y ], width: length - brand_width - gap,
        height: width - 2 * margin, size: [ 12, width / 2 ].min, align: :right)
    end
    pdf.render
  end

  private

  def draw_label(pdf, text, font:, **options)
    pdf.font(PhotoBookTypography.font_path(font).to_s)
    x, y = options.fetch(:at)
    center = [ x + options.fetch(:width) / 2, y - options.fetch(:height) / 2 ]
    # Reverse alignment along with the text so the end margins stay in place.
    alignment = { left: :right, right: :left }.fetch(options.fetch(:align))
    pdf.rotate(180, origin: center) do
      overflow = pdf.text_box(text, **options.merge(align: alignment), valign: :center, overflow: :shrink_to_fit, min_font_size: 2)
      raise ProdigiClient::Error, "The spine label does not fit. Shorten it before generating another PDF." if overflow.present?
    end
  end
end
