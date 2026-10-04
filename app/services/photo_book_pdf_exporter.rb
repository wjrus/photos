require "prawn"
require "vips"

class PhotoBookPdfExporter
  class InvalidDesign < StandardError; end

  def initialize(export, progress: nil)
    @export = export
    @snapshot = export.snapshot
    @progress = progress
    @layout = PhotoBookLayout.new(@snapshot)
  end

  def export
    preflight = PhotoBookPreflight.new(@export.photo_book, snapshot: @snapshot)
    raise InvalidDesign, preflight.errors.to_sentence unless preflight.ready?
    raise InvalidDesign, "A source photo is no longer available." unless @export.source_photos_available?

    output = Tempfile.create([ "photobook-", ".pdf" ], Rails.root.join("tmp"))
    path = output.path
    output.close
    Dir.mktmpdir("photobook-images-", Rails.root.join("tmp")) do |directory|
      @directory = directory
      @image_files = {}
      @photos = @export.photo_book.eligible_photos.where(id: @snapshot.fetch("photos").map { |source| source.fetch("id") }).with_attached_original.index_by(&:id)
      dimensions = PhotoBook::FORMATS.fetch(@snapshot.fetch("format"))
      @pdf = Prawn::Document.new(page_size: [ points(dimensions.fetch(:width)), points(dimensions.fetch(:height)) ], margin: 0,
        compress: true, info: { Title: @snapshot.fetch("title"), Creator: "Photos photobook designer" })
      @pdf.font(PhotoBookLayout::FONT_PATH.to_s)
      @layout.pages.each_with_index do |page, index|
        @pdf.start_new_page unless index.zero?
        draw_page(page)
        @progress&.call(index + 1)
      end
      @pdf.render_file(path)
    end
    path
  rescue StandardError
    FileUtils.rm_f(path) if path
    raise
  end

  private

  def draw_page(page)
    @pdf.fill_color(page.fetch(:background).delete_prefix("#"))
    @pdf.fill_rectangle([ 0, points(page.fetch(:height)) ], points(page.fetch(:width)), points(page.fetch(:height)))
    page.fetch(:images).each { |image| draw_image(image, page) }
    page.fetch(:panels).each do |panel|
      @pdf.fill_color(page.fetch(:background).delete_prefix("#"))
      @pdf.fill_rectangle([ points(panel.fetch(:x)), points(page.fetch(:height) - panel.fetch(:y)) ], points(panel.fetch(:width)), points(panel.fetch(:height)))
    end
    @pdf.fill_color(page.fetch(:color).delete_prefix("#"))
    page.fetch(:texts).each do |text|
      text.fetch(:lines).each_with_index do |line, index|
        baseline = text.fetch(:y) + text.fetch(:size) / PhotoBookLayout::POINTS_PER_MM + index * text.fetch(:line_height)
        @pdf.draw_text(line, at: [ points(text.fetch(:x)), points(page.fetch(:height) - baseline) ], size: text.fetch(:size))
      end
    end
  end

  def draw_image(image, page)
    key = image.values_at(:photo_id, :width, :height, :fit, :focus_x, :focus_y)
    file, width, height = @image_files[key] ||= prepare_image(image, page.fetch(:label))
    box = @layout.image_box(image, width: width, height: height)
    @pdf.image(file, at: [ points(box.fetch(:x) - page.fetch(:offset)), points(page.fetch(:height) - box.fetch(:y)) ],
      width: points(box.fetch(:width)), height: points(box.fetch(:height)))
  end

  def prepare_image(image, label)
    photo = @photos.fetch(image.fetch(:photo_id))
    photo.original.blob.open do |original|
      source = Vips::Image.new_from_file(original.path, access: :random).autorot
      source = if source.get_typeof("icc-profile-data").positive?
        source.icc_transform("srgb", embedded: true)
      else
        source.colourspace(:srgb)
      end
      source = source.flatten(background: [ 255, 255, 255 ]) if source.has_alpha?
      width, height = source.width, source.height
      box = @layout.image_box(image, width: width, height: height)
      dpi = [ width / box.fetch(:width), height / box.fetch(:height) ].min * 25.4
      if dpi < 299 && !@snapshot["allow_low_resolution"]
        raise InvalidDesign, "A photo on #{label} is #{dpi.round} DPI. Review and accept the resolution warning before exporting."
      end
      if image.fetch(:fit) == "fill"
        ratio = image.fetch(:width) / image.fetch(:height)
        crop_width = [ width, (height * ratio).round ].min
        crop_height = [ height, (width / ratio).round ].min
        left = ((width - crop_width) * image.fetch(:focus_x) / 100.0).round
        top = ((height - crop_height) * image.fetch(:focus_y) / 100.0).round
        source = source.crop(left, top, crop_width, crop_height)
      end
      print_width = image.fetch(:fit) == "fill" ? image.fetch(:width) : box.fetch(:width)
      target_width = print_width / 25.4 * 300
      scale = [ target_width / source.width, 1.0 ].min
      source = source.resize(scale) if scale < 1
      file = File.join(@directory, "#{@image_files.size}.jpg")
      source.jpegsave(file, Q: 95, strip: true)
      # Fill artwork is cropped already. Fit artwork retains its original ratio.
      [ file, source.width.to_f, source.height.to_f ]
    end
  end

  def points(mm)
    mm * PhotoBookLayout::POINTS_PER_MM
  end
end
