class AlbumsController < ApplicationController
  include PhotoStreamPagination

  before_action :require_owner!, except: %i[index show]
  before_action :set_visible_album, only: %i[show]
  before_action :set_album, only: %i[update publish unpublish destroy]

  def index
    @albums = PhotoAlbum.visible_to(current_user)
      .includes(:photos)
      .display_order
    @public_album_count = @albums.count(&:public?)
    @private_album_count = @albums.count(&:private?)
  end

  def show
    @photos, @next_cursor = paginate_photo_stream(@album.photos
      .with_attached_original
      .visible_to(current_user)
      .stream_order)
    @albums = current_user.photo_albums.display_order if current_user&.owner?

    render partial: "photos/page", locals: photo_page_locals(feature_first: false) if params[:cursor].present?
  end

  def create
    @album = current_user.photo_albums.new(album_params.merge(source: "manual"))
    @album.published_at = Time.current if @album.public?

    if @album.save
      redirect_to album_path(@album), notice: "Album created."
    else
      redirect_to albums_path, alert: @album.errors.full_messages.to_sentence
    end
  end

  def update
    if @album.update(album_params)
      @album.update!(published_at: @album.public? ? (@album.published_at || Time.current) : nil)
      redirect_to album_path(@album), notice: "Album updated."
    else
      redirect_to album_path(@album), alert: @album.errors.full_messages.to_sentence
    end
  end

  def publish
    @album.publish!
    redirect_to album_path(@album), notice: "Album published."
  end

  def unpublish
    @album.unpublish!
    redirect_to album_path(@album), notice: "Album returned to private."
  end

  def destroy
    @album.destroy!
    redirect_to albums_path, notice: "Album removed."
  end

  private

  def album_params
    params.require(:photo_album).permit(:title, :visibility)
  end

  def photo_page_locals(feature_first:)
    {
      photos: @photos,
      return_to: album_path(@album),
      feature_first: feature_first,
      bulk_form_id: "album-photo-bulk-form",
      owner_controls: current_user&.owner?,
      album: @album,
      next_cursor: @next_cursor,
      next_page_path: album_path(@album)
    }
  end

  def set_visible_album
    @album = PhotoAlbum.visible_to(current_user).find(params[:id])
  end

  def set_album
    @album = current_user.photo_albums.find(params[:id])
  end

  def require_owner!
    return if current_user&.owner?

    redirect_to root_path, alert: "Only the owner can manage albums."
  end
end
