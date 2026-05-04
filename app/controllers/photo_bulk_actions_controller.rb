class PhotoBulkActionsController < ApplicationController
  owner_access_message "Only the owner can manage photos."

  before_action :require_owner!

  def create
    photos = selected_photos
    return redirect_to safe_return_path, alert: "Select at least one photo." if photos.empty?

    case params[:bulk_action]
    when "publish"
      photos.find_each(&:publish!)
      redirect_to safe_return_path, notice: "Published #{photos.size} #{'photo'.pluralize(photos.size)}."
    when "unpublish"
      photos.find_each(&:unpublish!)
      redirect_to safe_return_path, notice: "Made #{photos.size} #{'photo'.pluralize(photos.size)} private."
    when "archive"
      photos.find_each(&:archive!)
      redirect_to safe_return_path, notice: "Archived #{photos.size} #{'photo'.pluralize(photos.size)}."
    when "restore"
      photos.find_each(&:restore!)
      redirect_to safe_return_path, notice: "Restored #{photos.size} #{'photo'.pluralize(photos.size)} to the stream."
    when "delete"
      count = photos.size
      photos.destroy_all
      redirect_to safe_return_path, notice: "Removed #{count} #{'photo'.pluralize(count)}."
    when "add_to_album"
      album = target_album
      return redirect_to safe_return_path, alert: "Choose an album or name a new one." unless album

      added = add_photos_to_album(photos, album)
      redirect_to safe_return_path, notice: "Added #{added} #{'photo'.pluralize(added)} to #{album.title}."
    else
      redirect_to safe_return_path, alert: "Choose an action."
    end
  end

  private

  def selected_photo_ids
    Array(params[:photo_ids]).compact_blank
  end

  def selected_photos
    scope = current_user.photos.where(restricted: false, id: selected_photo_ids)
    params[:bulk_action] == "restore" ? scope.archived : scope.not_archived
  end

  def target_album
    if params[:new_album_title].present?
      current_user.photo_albums.create!(title: params[:new_album_title].strip, source: "manual")
    elsif params[:album_id].present?
      current_user.photo_albums.find(params[:album_id])
    end
  end

  def add_photos_to_album(photos, album)
    photos.count do |photo|
      PhotoAlbumMembership.find_or_create_by!(photo: photo, photo_album: album).previously_new_record?
    end
  end
end
