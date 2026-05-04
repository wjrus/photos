class MapsController < ApplicationController
  MARKER_LIMIT = 500

  before_action :require_privileged_metadata_viewer!
  before_action :set_map_context

  def show
    @google_maps_api_key = ENV["GOOGLE_MAPS_EMBED_API_KEY"]
    @geotagged_photo_count = geotagged_photos.count
  end

  def markers
    marker_scope = geotagged_photos.in_map_bounds(map_bounds)
    total = marker_scope.count
    markers = marker_scope
      .with_attached_original
      .includes(:metadata)
      .stream_order
      .limit(MARKER_LIMIT)
      .map { |photo| marker_payload(photo) }

    render json: {
      markers: markers,
      total: total,
      limited: total > markers.size,
      limit: MARKER_LIMIT
    }
  end

  private

  def set_map_context
    @albums = PhotoAlbum.visible_to(current_user).display_order
    @selected_album = @albums.find_by(id: params[:album_id]) if params[:album_id].present?
    @map_return_path = @selected_album ? map_path(album_id: @selected_album.id) : map_path
  end

  def geotagged_photos
    scope = if @selected_album
      @selected_album.photos
    else
      Photo
    end

    scope
      .visible_to(current_user)
      .joins(:metadata)
      .where.not(photo_metadata: { latitude: nil, longitude: nil })
  end

  def marker_payload(photo)
    metadata = photo.metadata
    {
      id: photo.id,
      title: photo.title,
      latitude: metadata.latitude.to_f,
      longitude: metadata.longitude.to_f,
      photo_url: photo_path(photo, return_to: @map_return_path),
      media_url: photo.image? ? display_photo_path(photo) : nil
    }
  end

  def map_bounds
    {
      north: bounded_float(params[:north], -90, 90),
      south: bounded_float(params[:south], -90, 90),
      east: bounded_float(params[:east], -180, 180),
      west: bounded_float(params[:west], -180, 180)
    }.compact
  end

  def bounded_float(value, min, max)
    return if value.blank?

    Float(value).clamp(min, max)
  rescue ArgumentError, TypeError
    nil
  end

  def require_privileged_metadata_viewer!
    return if privileged_metadata_viewer?

    redirect_to root_path, alert: "Only trusted viewers can see the photo map."
  end
end
