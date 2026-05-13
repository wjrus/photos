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
    @google_maps_map_id = ENV["GOOGLE_MAPS_MAP_ID"].presence || "DEMO_MAP_ID"
    @geotagged_photo_count = geotagged_photos.count
    @initial_bounds = initial_map_bounds&.transform_values { |value| format("%.6f", value) }
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
    if request.format.json?
      @map_locations = []
      @selected_location = selected_location_from_param
      @map_return_path = map_path(map_filter_params)
      return
    end

    @map_locations = map_location_options
    @selected_location = @map_locations.find { |location| location.id == params[:location_id].to_s } if params[:location_id].present?
    @selected_location ||= selected_location_from_param
    @map_return_path = map_path(map_filter_params)
  end

  def geotagged_photos
    scope = if @selected_album
      @selected_album.photos
    else
      Photo
    end

    scope = scope
      .visible_to(current_user)
      .joins(:metadata)
      .where.not(photo_metadata: { latitude: nil, longitude: nil })

    @selected_location ? PhotoLocation.scope_for(scope, @selected_location.id) : scope
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
      photo_url: photo_path(photo),
      return_to: @map_return_path,
      media_url: map_media_url(photo)
    }
  end

  def location_payloads(scope)
    rows = location_rows(scope).to_a
    photos_by_id = preview_photos(rows)
    places = location_places(rows, photos_by_id)

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
    Photo.with_attached_original.with_attached_video_preview.includes(:metadata).where(id: ids).index_by(&:id)
  end

  def location_payload(row, count, photos_by_id, places)
    representative_photo = photos_by_id[row.representative_photo_id.to_i]
    location_id = if representative_photo
      PhotoLocation.id_for_coordinates(representative_photo.metadata.latitude, representative_photo.metadata.longitude)
    else
      PhotoLocation.id_for_coordinates(row.latitude, row.longitude)
    end

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
        .filter_map { |photo| map_media_url(photo) }
    }
  end

  def map_media_url(photo)
    return display_photo_path(photo) if photo.image?

    url_for(photo.video_preview) if photo.video? && photo.video_preview.attached?
  end

  def location_places(rows, photos_by_id)
    ids = rows.first(MARKER_LIMIT).map do |row|
      representative_photo = photos_by_id[row.representative_photo_id.to_i]
      if representative_photo
        PhotoLocation.id_for_coordinates(representative_photo.metadata.latitude, representative_photo.metadata.longitude)
      else
        PhotoLocation.id_for_coordinates(row.latitude, row.longitude)
      end
    end

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

  def initial_map_bounds
    explicit_bounds = map_bounds
    return explicit_bounds if explicit_bounds.values_at(:north, :south, :east, :west).all?
    return @selected_location.bounds.padded_bounds if @selected_location&.bounds
    return bounds_for(geotagged_photos) if @selected_location
    return unless @selected_album

    bounds_for(geotagged_photos)
  end

  def bounds_for(scope)
    row = scope.reselect(
      "MIN(photo_metadata.latitude) AS south",
      "MAX(photo_metadata.latitude) AS north",
      "MIN(photo_metadata.longitude) AS west",
      "MAX(photo_metadata.longitude) AS east"
    ).take
    return unless row&.south && row&.north && row&.west && row&.east

    south = row.south.to_f
    north = row.north.to_f
    west = row.west.to_f
    east = row.east.to_f
    latitude_padding = [ (north - south).abs * 0.5, 0.04 ].max
    longitude_padding = [ (east - west).abs * 0.5, 0.04 ].max

    {
      south: (south - latitude_padding).clamp(-90.0, 90.0),
      north: (north + latitude_padding).clamp(-90.0, 90.0),
      west: (west - longitude_padding).clamp(-180.0, 180.0),
      east: (east + longitude_padding).clamp(-180.0, 180.0)
    }
  end

  def map_markers_cache_key
    [
      "map-markers/v3",
      cache_audience_key,
      @selected_album&.id || "all",
      @selected_location&.id || "all",
      Photo.maximum(:updated_at)&.utc&.to_i,
      PhotoAlbumShare.maximum(:updated_at)&.utc&.to_i,
      PhotoAlbumShare.count,
      map_cell_size(params[:zoom]),
      normalized_map_bounds
    ]
  end

  def normalized_map_bounds
    map_bounds.sort.to_h.transform_values { |value| value.round(4) }
  end

  def map_filter_params
    {}.tap do |filters|
      filters[:album_id] = @selected_album.id if @selected_album
      filters[:location_id] = @selected_location.id if @selected_location
    end
  end

  def map_location_options
    rows = PhotoLocation.rows(map_location_options_scope).to_a
    places = location_places_for_rows(rows)
    bounds_by_id = PhotoLocationBound.where(location_id: grouped_location_ids(rows, places)).index_by(&:location_id)

    grouped_location_rows(rows, places).map do |location|
      location.bounds = bounds_by_id[location.id]
      location
    end
  end

  def selected_location_from_param
    location_id = params[:location_id].to_s
    return if location_id.blank? || !PhotoLocation.valid_id?(location_id)

    scope = PhotoLocation.scope_for(map_location_options_scope, location_id)
    return unless scope.exists?

    PhotoLocationGroup.new(
      id: location_id,
      title: selected_location_title(location_id, scope),
      photo_count: scope.count,
      bounds: PhotoLocationBound.find_by(location_id: location_id)
    )
  end

  def selected_location_title(location_id, scope)
    return PhotoLocation.place_name_from_id(location_id) if PhotoLocation.place_id?(location_id)

    row = PhotoLocation.rows(scope, limit: 1).first
    return location_id unless row

    PhotoLocation.title_for_row(row, location_places_for_rows([ row ]))
  end

  def map_location_options_scope
    scope = @selected_album ? @selected_album.photos : Photo
    scope
      .visible_to(current_user)
      .joins(:metadata)
      .where.not(photo_metadata: { latitude: nil, longitude: nil })
  end

  def location_places_for_rows(rows)
    ids = rows.map { |row| PhotoLocation.id_for(row.latitude_bucket, row.longitude_bucket) }
    PhotoLocationPlace.where(location_id: ids).index_by(&:location_id)
  end

  def grouped_location_ids(rows, places)
    rows.map do |row|
      location_id = PhotoLocation.id_for(row.latitude_bucket, row.longitude_bucket)
      place_name = places[location_id]&.name.presence
      place_name ? PhotoLocation.place_id_for_name(place_name) : location_id
    end.uniq
  end

  def grouped_location_rows(rows, places)
    groups = {}

    rows.each do |row|
      location_id = PhotoLocation.id_for(row.latitude_bucket, row.longitude_bucket)
      place_name = places[location_id]&.name.presence
      group_id = place_name ? PhotoLocation.place_id_for_name(place_name) : location_id
      title = place_name || PhotoLocation.title_for_row(row, places)

      groups[group_id] ||= PhotoLocationGroup.new(id: group_id, title: title)
      groups[group_id].add(row)
    end

    groups.values.sort_by { |location| location.title.to_s.downcase }
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
