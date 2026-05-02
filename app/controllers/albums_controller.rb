class AlbumsController < ApplicationController
  before_action :require_owner!, except: %i[index show]
  before_action :set_visible_album, only: %i[show]
  before_action :set_album, only: %i[publish unpublish destroy]

  def index
    @albums = PhotoAlbum.visible_to(current_user)
      .includes(:photos)
      .display_order
  end

  def show
    @photos = @album.photos
      .with_attached_original
      .visible_to(current_user)
      .stream_order
    @albums = current_user.photo_albums.display_order if current_user&.owner?
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
