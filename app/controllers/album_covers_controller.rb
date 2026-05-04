class AlbumCoversController < ApplicationController
  owner_access_message "Only the owner can manage albums."

  before_action :require_owner!

  def update
    album = current_user.photo_albums.find(params[:album_id])
    photo = album.photos.visible_to(current_user).find(params[:photo_id])
    album.update!(cover_photo: photo)

    redirect_to album_path(album), notice: "Album cover updated."
  end
end
