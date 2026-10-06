class PhotoBookExportsController < ApplicationController
  include ActionController::Live

  owner_access_message "Only the owner can export photobooks."
  before_action :require_owner!
  before_action :set_book
  before_action :set_export, only: %i[show file]
  before_action -> { response.set_header("Cache-Control", "private, no-store") }

  def create
    @book.with_lock do
      snapshot = @book.design_snapshot
      preflight = PhotoBookPreflight.new(@book, snapshot: snapshot)
      unless preflight.ready?
        return redirect_to photo_book_path(@book, anchor: "print-checks"), alert: "Resolve the print checks before exporting."
      end
      allow_low_resolution = params[:allow_low_resolution] == "1"
      if preflight.warnings.any? && !allow_low_resolution
        return redirect_to photo_book_path(@book, anchor: "print-checks"), alert: "Review and accept the resolution warnings before exporting."
      end
      digest = Digest::SHA256.hexdigest(snapshot.to_json)
      @export = @book.exports.find_by(design_digest: digest, status: %w[pending processing])
      unless @export
        snapshot["allow_low_resolution"] = allow_low_resolution
        @export = @book.exports.create!(snapshot: snapshot, design_digest: digest, filename: "#{@book.title.parameterize.presence || 'photobook'}-layflat.pdf")
        PreparePhotoBookExportJob.perform_later(@export)
      end
    end
    redirect_to photo_book_path(@book, anchor: "book-exports"), notice: "Your print PDF is being prepared. You can keep designing."
  end

  def show
    available = @export.ready? && @export.source_photos_available?
    render json: { status: @export.status, processed_pages: @export.processed_pages, total_pages: PhotoBookLayout.new(@export.snapshot).pages.size,
      error: @export.error, file_url: (file_photo_book_export_path(@book, @export) if available),
      order_url: (new_photo_book_order_path(@book, export_id: @export.id) if available) }
  end

  def file
    unless @export.ready? && @export.source_photos_available?
      return redirect_to photo_book_path(@book), alert: "This PDF is not available. Its source photos must remain available in the book."
    end
    # Keep private artwork behind authorization, including after a photo moves
    # to Private. Stream bytes instead of returning a public Active Storage URL.
    send_stream(filename: @export.filename, type: "application/pdf", disposition: "attachment") do |stream|
      @export.document.blob.download { |chunk| stream.write(chunk) }
    end
  end

  private

  def set_book
    @book = current_user.photo_books.find(params[:photo_book_id])
  end

  def set_export
    @export = @book.exports.find(params[:id])
  end
end
