class PhotoAlbumMembershipsController < ApplicationController
  owner_access_message "Only the owner can manage albums."

  before_action :require_owner!

  def create
    photo = current_user.photos.find(params[:photo_id])
    album = target_album
    return redirect_to safe_return_path(default: photo_path(photo)), alert: "Choose an album or name a new one." unless album

    membership = PhotoAlbumMembership.find_or_create_by!(photo: photo, photo_album: album)
    notice = if membership.previously_new_record?
      "Added to #{album.title}."
    else
      "Already in #{album.title}."
    end

    redirect_to safe_return_path(default: photo_path(photo)), notice: notice
  end

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

  def target_album
    if params[:new_album_title].present?
      current_user.photo_albums.create!(title: params[:new_album_title].strip, source: "manual")
    elsif params[:album_id].present?
      current_user.photo_albums.find(params[:album_id])
    end
  end
end
