class PhotoBulkActionsController < ApplicationController
  include PhotoStreamReturnPaths

  owner_access_message "Only the owner can manage photos."

  before_action :require_owner!

  def create
    photos = selected_photos.to_a
    return redirect_to safe_return_path, alert: "Select at least one photo." if photos.empty?

    case params[:bulk_action]
    when "publish"
      count = photos.size
      return_path = bulk_return_path(photos)
      photos.each(&:publish!)
      redirect_to return_path, notice: "Published #{count} #{'photo'.pluralize(count)}."
    when "unpublish"
      count = photos.size
      return_path = bulk_return_path(photos, removing_from_stream: public_return_path?)
      photos.each(&:unpublish!)
      redirect_to return_path, notice: "Unpublished #{count} #{'photo'.pluralize(count)}."
    when "archive"
      count = photos.size
      return_path = bulk_return_path(photos, removing_from_stream: true)
      photos.each(&:archive!)
      redirect_to return_path, notice: "Archived #{count} #{'photo'.pluralize(count)}."
    when "restrict"
      count = photos.size
      return_path = bulk_return_path(photos, removing_from_stream: true)
      photos.each(&:restrict!)
      redirect_to return_path, notice: "Moved #{count} #{'photo'.pluralize(count)} to Private."
    when "restore"
      count = photos.size
      return_path = bulk_return_path(photos, removing_from_stream: true)
      photos.each(&:restore!)
      redirect_to return_path, notice: "Restored #{count} #{'photo'.pluralize(count)} to the stream."
    when "remove_from_album"
      album = context_album
      return redirect_to safe_return_path, alert: "Open an album before removing photos from it." unless album

      return_path = bulk_return_path(photos, removing_from_stream: true)
      removed = remove_photos_from_album(photos, album)
      redirect_to return_path, notice: "Removed #{removed} #{'photo'.pluralize(removed)} from #{album.title}."
    when "set_album_cover"
      album = context_album
      return redirect_to safe_return_path, alert: "Open an album before setting its cover." unless album
      return redirect_to safe_return_path, alert: "Select exactly one photo to use as the album cover." unless photos.one?

      photo = album.photos.visible_to(current_user).find(photos.first.id)
      album.update!(cover_photo: photo)
      redirect_to bulk_return_path(photos), notice: "Album cover updated."
    when "delete"
      count = photos.size
      return_path = bulk_return_path(photos, removing_from_stream: true)
      photos.each(&:destroy!)
      redirect_to return_path, notice: "Removed #{count} #{'photo'.pluralize(count)}."
    when "add_to_album"
      album = target_album
      return redirect_to safe_return_path, alert: "Choose an album or name a new one." unless album

      added = add_photos_to_album(photos, album)
      redirect_to bulk_return_path(photos), notice: "Added #{added} #{'photo'.pluralize(added)} to #{album.title}."
    when "set_location"
      address = params[:location_address].to_s.squish
      return redirect_to safe_return_path, alert: "Enter an address or place name." if address.blank?

      image_photos = photos.select(&:image?)
      return redirect_to safe_return_path, alert: "Select at least one image photo." if image_photos.empty?

      result = LocationAddressGeocoder.new.geocode(address: address)
      unless result&.fetch(:latitude, nil).present? && result&.fetch(:longitude, nil).present?
        return redirect_to safe_return_path, alert: "Location not found."
      end

      image_photos.each do |photo|
        PhotoManualLocationAssigner.assign!(photo: photo, address: address, result: result)
      end

      skipped_count = photos.size - image_photos.size
      notice = "Set location for #{image_photos.size} #{'photo'.pluralize(image_photos.size)}."
      notice = "#{notice} Skipped #{skipped_count} non-image #{'item'.pluralize(skipped_count)}." if skipped_count.positive?
      redirect_to bulk_return_path(image_photos), notice: notice
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
    if params[:bulk_action] == "restore" || archive_return_path?(safe_return_path)
      scope.archived
    else
      scope.not_archived
    end
  end

  def bulk_return_path(photos, removing_from_stream: false)
    return_path = safe_return_path
    return return_path if params[:return_to].blank?

    if removing_from_stream
      photo_stream_return_path_after_removing(photos, return_path: return_path)
    else
      photo_stream_focused_return_path(photos.first, return_path: return_path)
    end
  end

  def archive_return_path?(return_path)
    URI.parse(return_path).path == archived_photos_path
  rescue URI::InvalidURIError
    false
  end

  def public_return_path?
    URI.parse(safe_return_path).path == public_photos_path
  rescue URI::InvalidURIError
    false
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

  def context_album
    current_user.photo_albums.find_by(id: params[:context_album_id])
  end

  def remove_photos_from_album(photos, album)
    removed_photo_ids = []
    album.photo_album_memberships.where(photo_id: photos.map(&:id)).find_each do |membership|
      removed_photo_ids << membership.photo_id
      membership.destroy!
    end
    if removed_photo_ids.include?(album.cover_photo_id)
      album.update!(cover_photo: album.replacement_cover(excluding_photo_ids: removed_photo_ids))
    end
    removed_photo_ids.size
  end
end
