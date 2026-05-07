class AlbumSharesController < ApplicationController
  owner_access_message "Only the owner can share albums."

  before_action :require_owner!

  def create
    album = current_user.photo_albums.find(params[:album_id])
    user = shareable_users.find(params[:user_id])
    share = PhotoAlbumShare.find_or_create_by!(photo_album: album, user: user) do |record|
      record.shared_by = current_user
    end
    share.update!(shared_by: current_user) unless share.shared_by

    redirect_to album_path(album), notice: "Shared with #{user.display_name}."
  end

  def destroy
    share = PhotoAlbumShare
      .joins(:photo_album)
      .where(photo_albums: { owner_id: current_user.id })
      .find(params[:id])
    album = share.photo_album
    user = share.user
    share.destroy!

    redirect_to album_path(album), notice: "Stopped sharing with #{user.display_name}."
  end

  private

  def shareable_users
    User.where(role: "viewer").where.not(invited_at: nil)
  end
end
