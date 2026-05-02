class PhotoBulkActionsController < ApplicationController
  before_action :require_owner!

  def create
    photos = current_user.photos.visible_to(current_user).where(id: selected_photo_ids)
    return redirect_to safe_return_path, alert: "Select at least one photo." if photos.empty?

    case params[:bulk_action]
    when "publish"
      photos.find_each(&:publish!)
      redirect_to safe_return_path, notice: "Published #{photos.size} #{'photo'.pluralize(photos.size)}."
    when "unpublish"
      photos.find_each(&:unpublish!)
      redirect_to safe_return_path, notice: "Made #{photos.size} #{'photo'.pluralize(photos.size)} private."
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

  def safe_return_path
    return root_path if params[:return_to].blank?

    uri = URI.parse(params[:return_to])
    return params[:return_to] if uri.relative?

    root_path
  rescue URI::InvalidURIError
    root_path
  end

  def require_owner!
    return if current_user&.owner?

    redirect_to root_path, alert: "Only the owner can manage photos."
  end
end
