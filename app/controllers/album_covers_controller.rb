class AlbumCoversController < ApplicationController
  before_action :require_owner!

  def update
    album = current_user.photo_albums.find(params[:album_id])
    photo = album.photos.visible_to(current_user).find(params[:photo_id])
    album.update!(cover_photo: photo)

    redirect_to album_path(album), notice: "Album cover updated."
  end

  private

  def require_owner!
    return if current_user&.owner?

    redirect_to root_path, alert: "Only the owner can manage albums."
  end
end
