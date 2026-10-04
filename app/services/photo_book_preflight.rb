class PhotoBookPreflight
  attr_reader :errors, :warnings, :layout, :snapshot

  def initialize(book, snapshot: book.design_snapshot)
    @book = book
    @snapshot = snapshot
    @layout = PhotoBookLayout.new(snapshot)
    @errors = layout.errors.dup
    @warnings = []
    check_page_count
    check_photos
    @errors.uniq!
    @warnings.uniq!
  end

  def ready?
    errors.empty?
  end

  private

  def check_page_count
    count = layout.pages.size
    @errors << "The print PDF needs #{PhotoBook::MIN_PRINTED_PAGES}–#{PhotoBook::MAX_PRINTED_PAGES} pages including the front and back covers (currently #{count})." unless (PhotoBook::MIN_PRINTED_PAGES..PhotoBook::MAX_PRINTED_PAGES).cover?(count)
    @errors << "The print PDF needs an even page count. Add or remove a page." if count.odd?
  end

  def check_photos
    sources = snapshot.fetch("photos").index_by { |photo| photo.fetch("id") }
    eligible = @book.eligible_photos.where(id: sources.keys).with_attached_original.index_by(&:id)
    layout.pages.each do |page|
      page.fetch(:images).each do |image|
        id = image.fetch(:photo_id)
        if id.nil?
          @errors << "#{page.fetch(:label)} needs a photo. Choose one or change its layout to Blank page."
          next
        end
        photo = eligible[id]
        source = sources[id]
        unless photo&.original&.attached? && source && photo.original.blob.id == source.fetch("blob_id")
          @errors << "A photo on #{page.fetch(:label)} is unavailable, archived, or in Private. Replace it before exporting."
          next
        end
        width, height = source.values_at("width", "height").map(&:to_f)
        unless width.positive? && height.positive?
          @warnings << "Image dimensions are not available for a photo on #{page.fetch(:label)}. Resolution will be checked during export."
          next
        end
        fitted = layout.image_box(image, width: width, height: height)
        dpi = [ width / fitted.fetch(:width), height / fitted.fetch(:height) ].min * 25.4
        @warnings << "A photo on #{page.fetch(:label)} prints at about #{dpi.round} DPI; 300 DPI is recommended." if dpi < 299
      end
    end
  end
end
