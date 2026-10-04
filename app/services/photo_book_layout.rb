require "prawn"

# All coordinates are millimetres from the top left. Preview and PDF use the
# same geometry and font metrics; spreads are clipped into two single pages.
class PhotoBookLayout
  POINTS_PER_MM = 72.0 / 25.4
  FONT_PATH = Rails.root.join("app/assets/fonts/NotoSans-Regular.ttf")

  attr_reader :snapshot, :pages, :errors

  def initialize(snapshot)
    @snapshot = snapshot
    dimensions = PhotoBook::FORMATS.fetch(snapshot.fetch("format"))
    @width = dimensions.fetch(:width).to_f
    @height = dimensions.fetch(:height).to_f
    @font_document = Prawn::Document.new
    @font_document.font(FONT_PATH.to_s)
    @cmap = TTFunk::File.open(FONT_PATH.to_s).cmap.unicode.first
    @errors = []
    @pages = build_pages
  end

  def facing_pages(key)
    selected = pages.find { |page| page.fetch(:key) == key } || pages.first
    return [ selected ] if selected[:number].nil?

    number = selected.fetch(:number)
    left_number = number.even? ? number : number - 1
    [ pages.find { |page| page[:number] == left_number }, pages.find { |page| page[:number] == left_number + 1 } ]
  end

  def image_box(image, width:, height:)
    return image.slice(:x, :y, :width, :height) unless width.to_f.positive? && height.to_f.positive?

    scales = [ image.fetch(:width) / width, image.fetch(:height) / height ]
    scale = image.fetch(:fit) == "fit" ? scales.min : scales.max
    fitted_width, fitted_height = width * scale, height * scale
    {
      x: image.fetch(:x) + (image.fetch(:width) - fitted_width) * image.fetch(:focus_x) / 100.0,
      y: image.fetch(:y) + (image.fetch(:height) - fitted_height) * image.fetch(:focus_y) / 100.0,
      width: fitted_width, height: fitted_height
    }
  end

  private

  def build_pages
    built = [ cover(:front) ]
    number = 1
    snapshot.fetch("pages").each do |source|
      spread = source.fetch("layout") == "spread"
      @errors << "A two-page photo must start on a left-hand page (currently page #{number}). Add a blank page before it or reorder pages." if spread && number.odd?
      canvas = canvas_for(source, width: spread ? @width * 2 : @width)
      (spread ? 2 : 1).times do |half|
        built << canvas.merge(key: "#{source.fetch('id')}-#{half}", source_id: source.fetch("id"), number: number,
          label: "Page #{number}", offset: half * @width, side: number.even? ? "left" : "right")
        number += 1
      end
    end
    built << cover(:back)
    built
  end

  def cover(side)
    front = side == :front
    canvas = base_canvas
    photo_id = snapshot[front ? "cover_photo_id" : "back_photo_id"]
    full = snapshot.fetch("cover_layout") == "full"
    if photo_id
      canvas[:images] << image(photo_id, full ? [ 0, 0, @width, @height ] : [ 10, 10, @width - 20, @height * 0.65 - 10 ], fit: full ? "fill" : "fit")
    end
    if front
      # Cover text always stays in a solid panel, making it legible on a full photo.
      canvas[:panels] << { x: 10, y: @height * 0.7, width: @width - 20, height: @height * 0.3 - 20 }
      canvas[:texts] << text(snapshot.fetch("cover_title"), [ 15, @height * 0.71, @width - 30, @height * 0.16 ], size: 24, label: "Cover title")
      canvas[:texts] << text(snapshot.fetch("cover_subtitle"), [ 15, @height * 0.87, @width - 30, @height * 0.13 - 12 ], size: 11, label: "Cover subtitle")
    else
      canvas[:panels] << { x: 10, y: @height * 0.7, width: @width - 20, height: @height * 0.3 - 20 }
      canvas[:texts] << text(snapshot.fetch("back_text"), [ 15, @height * 0.71, @width - 30, @height * 0.29 - 22 ], size: 11, label: "Back cover text")
    end
    canvas.merge(key: side.to_s, label: front ? "Front cover" : "Back cover", number: nil, offset: 0)
  end

  def canvas_for(source, width:)
    canvas = base_canvas.merge(canvas_width: width)
    fit = source.fetch("image_fit")
    primary = ->(box, sizing = fit) { image(source["primary_photo_id"], box, fit: sizing, focus_x: source.fetch("primary_focus_x"), focus_y: source.fetch("primary_focus_y")) }
    secondary = ->(box) { image(source["secondary_photo_id"], box, fit: fit, focus_x: source.fetch("secondary_focus_x"), focus_y: source.fetch("secondary_focus_y")) }
    case source.fetch("layout")
    when "full", "spread"
      canvas[:images] << primary.call([ 0, 0, width, @height ], "fill")
    when "fit"
      canvas[:images] << primary.call([ 10, 10, width - 20, @height - 20 ], "fit")
    when "caption"
      caption_height = @height * 0.18
      canvas[:images] << primary.call([ 10, 10, width - 20, @height - caption_height - 25 ])
      canvas[:texts] << text(source.fetch("caption"), [ 10, @height - caption_height - 10, width - 20, caption_height ], label: "Photo caption")
    when "two_horizontal"
      slot_width = (width - 25) / 2
      image_height = @height * 0.68
      [ primary.call([ 10, 10, slot_width, image_height ]), secondary.call([ 15 + slot_width, 10, slot_width, image_height ]) ].each { |item| canvas[:images] << item }
      canvas[:texts] << text(source.fetch("caption"), [ 10, image_height + 15, slot_width, @height - image_height - 25 ], label: "First photo caption")
      canvas[:texts] << text(source.fetch("secondary_caption"), [ 15 + slot_width, image_height + 15, slot_width, @height - image_height - 25 ], label: "Second photo caption")
    when "two_vertical"
      slot_height = (@height - 25) / 2
      image_height = slot_height * 0.7
      canvas[:images] << primary.call([ 10, 10, width - 20, image_height ])
      canvas[:images] << secondary.call([ 10, slot_height + 15, width - 20, image_height ])
      canvas[:texts] << text(source.fetch("caption"), [ 10, image_height + 12, width - 20, slot_height - image_height - 2 ], label: "First photo caption")
      canvas[:texts] << text(source.fetch("secondary_caption"), [ 10, slot_height + image_height + 17, width - 20, slot_height - image_height - 2 ], label: "Second photo caption")
    when "text"
      canvas[:texts] << text(source.fetch("caption"), [ 15, 20, width - 30, @height - 40 ], size: 14, label: "Page text")
    end
    canvas
  end

  def base_canvas
    { width: @width, height: @height, canvas_width: @width, images: [], texts: [], panels: [], background: snapshot.fetch("background_color"), color: snapshot.fetch("text_color") }
  end

  def image(photo_id, box, fit: "fill", focus_x: 50, focus_y: 50)
    { photo_id: photo_id, x: box[0], y: box[1], width: box[2], height: box[3], fit: fit, focus_x: focus_x, focus_y: focus_y }
  end

  def text(content, box, size: 11, label:)
    normalized = content.to_s.gsub(/\r\n?/, "\n")
    unsupported = normalized.codepoints.reject { |codepoint| codepoint == 10 || @cmap[codepoint].to_i.positive? }.uniq
    @errors << "#{label} contains characters the print font cannot display. Remove unsupported symbols or emoji." if unsupported.any?
    lines = wrap_text(normalized, width: box[2], size: size)
    line_height = size * 1.4 / POINTS_PER_MM
    @errors << "#{label} does not fit. Shorten the text or choose a text page." if lines.size * line_height > box[3]
    { x: box[0], y: box[1], width: box[2], height: box[3], size: size, line_height: line_height, lines: lines }
  end

  def wrap_text(content, width:, size:)
    content.split("\n", -1).flat_map do |paragraph|
      line = ""
      lines = []
      paragraph.split(/\s+/).each do |word|
        candidate = line.empty? ? word : "#{line} #{word}"
        if text_width(candidate, size) <= width
          line = candidate
        else
          lines << line unless line.empty?
          line = ""
          word.each_char do |character|
            if text_width(line + character, size) > width && line.present?
              lines << line
              line = ""
            end
            line += character
          end
        end
      end
      lines << line
      lines
    end
  end

  def text_width(content, size)
    @font_document.width_of(content, size: size) / POINTS_PER_MM
  end
end
