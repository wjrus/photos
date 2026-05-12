module PhotoStreamReturnPaths
  extend ActiveSupport::Concern

  private

  def photo_stream_focused_return_path(photo, return_path: safe_return_path)
    uri = URI.parse(return_path)
    return return_path unless photo_stream_return_path?(uri.path)

    photo_stream_return_path_with_focus(uri, photo)
  rescue URI::InvalidURIError
    return_path
  end

  def photo_stream_return_path_after_removing(photos, return_path: safe_return_path)
    uri = URI.parse(return_path)
    return return_path unless photo_stream_return_path?(uri.path)

    anchor = photo_stream_anchor_after_removing(photos, uri)
    anchor ? photo_stream_return_path_with_focus(uri, anchor) : return_path
  rescue URI::InvalidURIError
    return_path
  end

  def photo_stream_return_path_with_focus(uri, photo)
    query = Rack::Utils.parse_nested_query(uri.query)
    query.except!("cursor", "newer_cursor", "stream_page")
    query["photo_id"] = photo.id
    uri.query = query.to_query.presence
    uri.to_s
  end

  def photo_stream_anchor_after_removing(photos, uri)
    selected_ids = photos.map(&:id)
    stream = photo_stream_return_scope(uri)
    return unless stream

    order = photo_stream_return_order(uri)
    ordered_selected = photo_stream_ordered_scope(stream.where(id: selected_ids), order).to_a
    return if ordered_selected.empty?

    remaining_stream = photo_stream_ordered_scope(stream.where.not(id: selected_ids), order)
    photo_stream_after(remaining_stream, ordered_selected.last, order) ||
      photo_stream_before(remaining_stream, ordered_selected.first, order)
  end

  def photo_stream_return_path?(path)
    path == root_path ||
      path == search_path ||
      path == public_photos_path ||
      path == archived_photos_path ||
      path == restricted_photos_path ||
      path.match?(%r{\A/albums/\d+\z}) ||
      path.match?(%r{\A/locations/[^/]+\z})
  end

  def photo_stream_return_scope(uri)
    case uri.path
    when root_path
      Photo.visible_to(current_user).stream_order
    when public_photos_path
      current_user.photos.publicly_visible.stream_order if current_user&.owner?
    when archived_photos_path
      current_user.photos.archived.stream_order
    when restricted_photos_path
      current_user.photos.restricted.stream_order if current_user&.owner?
    when search_path
      photo_stream_search_scope(uri)
    else
      photo_stream_album_scope(uri) || photo_stream_location_scope(uri)
    end
  end

  def photo_stream_album_scope(uri)
    album_id = uri.path.match(%r{\A/albums/(\d+)\z})&.[](1)
    return unless album_id

    PhotoAlbum.visible_to(current_user).find_by(id: album_id)&.photos&.visible_to(current_user)&.chronological_order
  end

  def photo_stream_location_scope(uri)
    location_id = uri.path.match(%r{\A/locations/([^/]+)\z})&.[](1)
    return unless location_id && PhotoLocation.valid_id?(location_id)

    PhotoLocation.scope_for(photo_stream_geotagged_photo_scope, location_id).stream_order
  end

  def photo_stream_search_scope(uri)
    query = Rack::Utils.parse_nested_query(uri.query).symbolize_keys.slice(*PhotoSearch::FILTER_PARAMS)
    search = PhotoSearch.new(params: query, user: current_user)

    Photo
      .visible_to(current_user)
      .where(id: search.results.except(:order).select(:id))
      .stream_order
  end

  def photo_stream_geotagged_photo_scope
    Photo
      .visible_to(current_user)
      .joins(:metadata)
      .where.not(photo_metadata: { latitude: nil, longitude: nil })
  end

  def photo_stream_return_order(uri)
    uri.path.match?(%r{\A/albums/\d+\z}) ? :chronological : :stream
  end

  def photo_stream_ordered_scope(scope, order)
    order == :chronological ? scope.chronological_order : scope.stream_order
  end

  def photo_stream_after(scope, photo, order)
    if order == :chronological
      scope.after_chronological_cursor(photo.stream_cursor).chronological_order.first
    else
      scope.stream_after(photo)
    end
  end

  def photo_stream_before(scope, photo, order)
    if order == :chronological
      scope.chronological_before(photo)
    else
      scope.stream_before(photo)
    end
  end
end
