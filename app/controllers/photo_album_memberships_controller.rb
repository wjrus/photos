class PhotoAlbumMembershipsController < ApplicationController
  before_action :require_owner!

  def destroy
    membership = PhotoAlbumMembership
      .joins(:photo_album)
      .where(photo_albums: { owner_id: current_user.id })
      .find(params[:id])
    album = membership.photo_album
    membership.destroy!
    album.update!(cover_photo: nil) if album.cover_photo_id == membership.photo_id

    redirect_to album_path(album), notice: "Photo removed from album."
  end

  private

  def require_owner!
    return if current_user&.owner?

    redirect_to root_path, alert: "Only the owner can manage albums."
  end
end
