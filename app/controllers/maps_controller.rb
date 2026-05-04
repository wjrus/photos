class MapsController < ApplicationController
  MARKER_LIMIT = 500
  CLUSTER_SELECT_SQL = <<~SQL.squish
    FLOOR(photo_metadata.latitude / :cell_size) AS latitude_bucket,
    FLOOR(photo_metadata.longitude / :cell_size) AS longitude_bucket,
    COUNT(*) AS photo_count,
    AVG(photo_metadata.latitude) AS latitude,
    AVG(photo_metadata.longitude) AS longitude,
    (ARRAY_AGG(photos.id ORDER BY COALESCE(photos.captured_at, photos.created_at) DESC, photos.id DESC))[1] AS representative_photo_id,
    (ARRAY_AGG(photos.id ORDER BY COALESCE(photos.captured_at, photos.created_at) DESC, photos.id DESC))[1:6] AS preview_photo_ids
  SQL

  before_action :require_privileged_metadata_viewer!
  before_action :set_map_context

  def show
    @google_maps_api_key = ENV["GOOGLE_MAPS_EMBED_API_KEY"]
    @geotagged_photo_count = geotagged_photos.count
  end

  def markers
    render json: Rails.cache.fetch(map_markers_cache_key, expires_in: 5.minutes, race_condition_ttl: 10.seconds) {
      marker_scope = geotagged_photos.in_map_bounds(map_bounds)
      total = marker_scope.count
      markers = location_payloads(marker_scope)

      {
        markers: markers,
        total: total,
        locations: markers.size,
        limited: total > markers.size,
        limit: MARKER_LIMIT
      }
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
      type: "photo",
      id: photo.id,
      title: photo.title,
      count: 1,
      latitude: metadata.latitude.to_f,
      longitude: metadata.longitude.to_f,
      photo_url: photo_path(photo, return_to: @map_return_path),
      media_url: photo.image? ? display_photo_path(photo) : nil
    }
  end

  def location_payloads(scope)
    rows = location_rows(scope)
    photos_by_id = preview_photos(rows)
    places = location_places(rows)

    rows.first(MARKER_LIMIT).filter_map do |row|
      count = row.photo_count.to_i
      if count == 1
        photo = photos_by_id[row.representative_photo_id.to_i]
        marker_payload(photo) if photo
      else
        location_payload(row, count, photos_by_id, places)
      end
    end
  end

  def location_rows(scope)
    cell_size = map_cell_size(params[:zoom])
    bucket_sql = Photo.sanitize_sql_array([ CLUSTER_SELECT_SQL, { cell_size: cell_size } ])
    latitude_bucket_sql = Photo.sanitize_sql_array([ "FLOOR(photo_metadata.latitude / :cell_size)", { cell_size: cell_size } ])
    longitude_bucket_sql = Photo.sanitize_sql_array([ "FLOOR(photo_metadata.longitude / :cell_size)", { cell_size: cell_size } ])

    scope
      .select(bucket_sql)
      .group(Arel.sql(latitude_bucket_sql), Arel.sql(longitude_bucket_sql))
      .order(Arel.sql("photo_count DESC"))
      .limit(MARKER_LIMIT + 1)
  end

  def preview_photos(rows)
    ids = rows.first(MARKER_LIMIT).flat_map { |row| Array(row.preview_photo_ids).map(&:to_i) }
    Photo.with_attached_original.includes(:metadata).where(id: ids).index_by(&:id)
  end

  def location_payload(row, count, photos_by_id, places)
    location_id = PhotoLocation.id_for(
      (row.latitude.to_f / PhotoLocation::CELL_SIZE).floor,
      (row.longitude.to_f / PhotoLocation::CELL_SIZE).floor
    )

    {
      type: "location",
      id: "location-#{row.latitude_bucket.to_i}-#{row.longitude_bucket.to_i}",
      title: PhotoLocation.title_for_row(row, places),
      count: count,
      latitude: row.latitude.to_f,
      longitude: row.longitude.to_f,
      location_url: location_path(location_id),
      preview_urls: Array(row.preview_photo_ids)
        .filter_map { |id| photos_by_id[id.to_i] }
        .select(&:image?)
        .map { |photo| display_photo_path(photo) }
    }
  end

  def location_places(rows)
    ids = rows.first(MARKER_LIMIT).map { |row| PhotoLocation.id_for_coordinates(row.latitude, row.longitude) }
    PhotoLocationPlace.where(location_id: ids).index_by(&:location_id)
  end

  def map_cell_size(zoom)
    zoom = bounded_float(zoom, 1, 21) || 4
    case zoom
    when ...5 then 5.0
    when ...7 then 2.0
    when ...9 then 0.5
    when ...11 then 0.1
    when ...13 then 0.025
    when ...15 then 0.005
    else 0.0005
    end
  end

  def map_bounds
    {
      north: bounded_float(params[:north], -90, 90),
      south: bounded_float(params[:south], -90, 90),
      east: bounded_float(params[:east], -180, 180),
      west: bounded_float(params[:west], -180, 180)
    }.compact
  end

  def map_markers_cache_key
    [
      "map-markers/v3",
      cache_audience_key,
      @selected_album&.id || "all",
      map_cell_size(params[:zoom]),
      normalized_map_bounds
    ]
  end

  def normalized_map_bounds
    map_bounds.sort.to_h.transform_values { |value| value.round(4) }
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
