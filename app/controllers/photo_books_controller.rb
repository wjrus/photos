class PhotoBooksController < ApplicationController
  owner_access_message "Only the owner can design photobooks."
  before_action :require_owner!
  before_action :set_book, except: %i[index new create]
  before_action :private_response

  def index
    @page = [ params[:page].to_i, 1 ].max
    @books = current_user.photo_books.order(updated_at: :desc, id: :desc).offset((@page - 1) * 20).limit(21).to_a
    @next_page = @page + 1 if @books.size > 20
    @books = @books.first(20)
    @photo_counts = PhotoBookMembership.where(photo_book_id: @books.map(&:id)).group(:photo_book_id).count
    @page_counts = PhotoBookPage.where(photo_book_id: @books.map(&:id)).group(:photo_book_id).sum(Arel.sql("CASE WHEN layout = 'spread' THEN 2 ELSE 1 END"))
    @covers = current_user.photos.where(id: @books.filter_map(&:cover_photo_id), restricted: false, archived_at: nil).index_by(&:id)
  end

  def new
    @book = current_user.photo_books.new
  end

  def create
    @book = current_user.photo_books.new(book_params)
    @book.cover_title = @book.title if @book.cover_title.blank?
    @book.save!
    redirect_to photo_book_path(@book), notice: "Photobook created. Add photos from your library or an album, then design its pages."
  rescue ActiveRecord::RecordInvalid
    render :new, status: :unprocessable_entity
  end

  def show
    prepare_designer
  end

  def tray
    snapshot = draft_snapshot
    return head :unprocessable_entity unless snapshot

    prepare_tray(PhotoBookLayout.new(snapshot))
    if request.format.turbo_stream?
      render turbo_stream: turbo_stream.replace("photobook-tray", partial: "photo_books/photo_tray")
    else
      render partial: "photo_books/photo_tray"
    end
  end

  def edit
    @photo_options = @book.eligible_photos.order(:id).pluck(:title, :id)
  end

  def update
    if @book.update(book_params)
      key = %w[front back].include?(params[:preview_key]) ? params[:preview_key] : "front"
      redirect_to photo_book_path(@book, page_id: key), notice: "Book settings saved."
    else
      edit
      render :edit, status: :unprocessable_entity
    end
  rescue ActiveRecord::StaleObjectError
    redirect_to edit_photo_book_path(@book), alert: "This book changed in another tab. Reload its settings before saving."
  end

  def destroy
    if @book.destroy
      redirect_to photo_books_path, notice: "Photobook removed. Its photos remain in your library."
    else
      redirect_to photo_book_path(@book), alert: @book.errors.full_messages.to_sentence
    end
  end

  def preview
    snapshot = draft_snapshot
    return head :unprocessable_entity unless snapshot

    layout = PhotoBookLayout.new(snapshot)
    photos = preview_photos(snapshot)
    prepare_preview(layout)
    render turbo_stream: turbo_stream.replace("photobook-preview", partial: "photo_books/preview", locals: {
      layout: layout, preview_pages: @preview_pages, preview_mode: @preview_mode, photos: photos, book: @book, selected_key: @selected_key
    })
  end

  private

  def set_book
    @book = current_user.photo_books.find(params[:id])
  end

  def private_response
    response.set_header("Cache-Control", "private, no-store")
    response.set_header("X-Robots-Tag", "noindex, nofollow")
  end

  def book_params
    params.require(:photo_book).permit(:title, :format, :cover_layout, :cover_title, :cover_subtitle, :back_text, :spine_text,
      :background_color, :text_color, :cover_photo_id, :back_photo_id, :lock_version, *PhotoBook::COVER_POSITION_ATTRIBUTES,
      cover_style: PhotoBookTypography::KEYS, back_style: PhotoBookTypography::KEYS)
  end

  def draft_snapshot
    snapshot = @book.design_snapshot
    if params[:page_id].present?
      page = @book.pages.find(params[:page_id])
      @selected_page = page
      page.assign_attributes(params.fetch(:photo_book_page, {}).permit(*PhotoBookPage::DESIGN_ATTRIBUTES)) if params[:photo_book_page]
      return unless page.valid?

      snapshot["pages"].find { |source| source.fetch("id") == page.id }.merge!(page.attributes.slice(*PhotoBookPage::DESIGN_ATTRIBUTES))
      @selected_key = page_preview_key(page, params[:preview_key])
    else
      @selected_key = params[:preview_key] == "back" ? "back" : "front"
      if params[:photo_book]
        attributes = params.require(:photo_book).permit(:cover_photo_id, :back_photo_id, :cover_layout, :cover_title, :cover_subtitle, :back_text, *PhotoBook::COVER_POSITION_ATTRIBUTES,
          cover_style: PhotoBookTypography::KEYS, back_style: PhotoBookTypography::KEYS)
        @book.assign_attributes(attributes)
        return unless @book.valid?

        snapshot.merge!(@book.attributes.slice(*attributes.keys))
      end
    end
    snapshot
  end

  def prepare_tray(layout)
    @tray_used_ids = layout.pages.flat_map { |page| page.fetch(:images).pluck(:photo_id) }.compact.uniq
    @tray_show_used = params[:show_used] == "1"
    @tray_search = params[:tray_search].to_s.strip.first(200)
    @tray_page = [ params[:tray_page].to_i, 1 ].max
    scope = @book.eligible_photos
    @tray_unused_count = scope.where.not(id: @tray_used_ids).count
    scope = scope.where.not(id: @tray_used_ids) unless @tray_show_used
    scope = scope.where("photos.title ILIKE ?", "%#{Photo.sanitize_sql_like(@tray_search)}%") if @tray_search.present?
    @tray_photos = scope.chronological_order.with_original_variant_records.offset((@tray_page - 1) * 24).limit(25).to_a
    @tray_next_page = @tray_page + 1 if @tray_photos.size > 24
    @tray_photos = @tray_photos.first(24)
  end

  def prepare_designer
    @snapshot = @book.design_snapshot
    @preflight = PhotoBookPreflight.new(@book, snapshot: @snapshot)
    @layout = @preflight.layout
    key = params[:page_id].presence || "front"
    @selected_page = @book.pages.find_by(id: key.to_s.split("-").first) unless %w[front back].include?(key)
    @selected_key = @selected_page ? page_preview_key(@selected_page, key) : %w[front back].include?(key) ? key : "front"
    prepare_preview(@layout)
    @preview_photos = preview_photos(@snapshot)
    @photo_count = @book.eligible_photos.count
    @tab = params[:tab] == "photos" ? "photos" : "design"
    if @tab == "photos"
      @photo_page = [ params[:photo_page].to_i, 1 ].max
      @photo_search = params[:photo_search].to_s.strip.first(200)
      scope = @book.eligible_photos
      scope = scope.where("photos.title ILIKE ?", "%#{Photo.sanitize_sql_like(@photo_search)}%") if @photo_search.present?
      @pool_photos = scope.chronological_order.with_original_variant_records.offset((@photo_page - 1) * 24).limit(25).to_a
      @next_photo_page = @photo_page + 1 if @pool_photos.size > 24
      @pool_photos = @pool_photos.first(24)
      @albums = current_user.photo_albums.display_order
    else
      prepare_tray(@layout)
    end
    @exports = @book.exports.limit(3)
    @orders = @book.orders.order(created_at: :desc).limit(10)
  end

  def preview_photos(snapshot)
    ids = [ snapshot["cover_photo_id"], snapshot["back_photo_id"] ] + snapshot.fetch("pages").flat_map { |page| page.values_at("primary_photo_id", "secondary_photo_id") }
    @book.eligible_photos.where(id: ids.compact).includes(:print_metadata).index_by(&:id)
  end

  def page_preview_key(page, key)
    half = page.layout == "spread" && key == "#{page.id}-1" ? 1 : 0
    "#{page.id}-#{half}"
  end

  def prepare_preview(layout)
    @preview_mode = params[:view] == "spread" ? "spread" : "page"
    @preview_pages = @preview_mode == "spread" ? layout.facing_pages(@selected_key) : [ layout.pages.find { |page| page.fetch(:key) == @selected_key } || layout.pages.first ]
  end
end
