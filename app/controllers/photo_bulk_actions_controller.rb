class PhotoBulkActionsController < ApplicationController
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
      return_path = bulk_return_path(photos)
      photos.each(&:unpublish!)
      redirect_to return_path, notice: "Made #{count} #{'photo'.pluralize(count)} private."
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
    uri = URI.parse(return_path)
    return return_path unless stream_return_path?(uri.path)

    anchor = if removing_from_stream
      stream_anchor_after_removing(photos, uri)
    else
      photos.first
    end

    anchor ? focused_return_path(uri, anchor) : return_path
  rescue URI::InvalidURIError
    return_path
  end

  def focused_return_path(uri, photo)
    query = Rack::Utils.parse_nested_query(uri.query)
    query.except!("cursor", "newer_cursor", "stream_page")
    query["photo_id"] = photo.id
    uri.query = query.to_query.presence
    uri.to_s
  end

  def stream_anchor_after_removing(photos, uri)
    selected_ids = photos.map(&:id)
    stream = return_stream_scope(uri)
    return unless stream

    ordered_selected = stream.where(id: selected_ids).stream_order.to_a
    return if ordered_selected.empty?

    remaining_stream = stream.where.not(id: selected_ids).stream_order
    remaining_stream.stream_after(ordered_selected.last) || remaining_stream.stream_before(ordered_selected.first)
  end

  def stream_return_path?(path)
    path == root_path ||
      path == search_path ||
      path == archived_photos_path ||
      path.match?(%r{\A/albums/\d+\z}) ||
      path.match?(%r{\A/locations/[^/]+\z})
  end

  def archive_return_path?(return_path)
    URI.parse(return_path).path == archived_photos_path
  rescue URI::InvalidURIError
    false
  end

  def return_stream_scope(uri)
    case uri.path
    when root_path
      Photo.visible_to(current_user).stream_order
    when archived_photos_path
      current_user.photos.archived.stream_order
    when search_path
      search_stream_scope(uri)
    else
      album_stream_scope(uri) || location_stream_scope(uri)
    end
  end

  def album_stream_scope(uri)
    album_id = uri.path.match(%r{\A/albums/(\d+)\z})&.[](1)
    return unless album_id

    PhotoAlbum.visible_to(current_user).find_by(id: album_id)&.photos&.visible_to(current_user)&.stream_order
  end

  def location_stream_scope(uri)
    location_id = uri.path.match(%r{\A/locations/([^/]+)\z})&.[](1)
    return unless location_id && PhotoLocation.valid_id?(location_id)

    PhotoLocation.scope_for(geotagged_photo_scope, location_id).stream_order
  end

  def search_stream_scope(uri)
    query = Rack::Utils.parse_nested_query(uri.query).symbolize_keys.slice(*PhotoSearch::FILTER_PARAMS)
    search = PhotoSearch.new(params: query, user: current_user)

    Photo
      .visible_to(current_user)
      .where(id: search.results.except(:order).select(:id))
      .stream_order
  end

  def geotagged_photo_scope
    Photo
      .visible_to(current_user)
      .joins(:metadata)
      .where.not(photo_metadata: { latitude: nil, longitude: nil })
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
    album.update!(cover_photo: nil) if removed_photo_ids.include?(album.cover_photo_id)
    removed_photo_ids.size
  end
end
