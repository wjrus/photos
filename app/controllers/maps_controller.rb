class MapsController < ApplicationController
  MARKER_LIMIT = 500
  REGION_MAX_ZOOM = 10
  CLUSTER_SELECT_SQL = <<~SQL.squish
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
    render json: cache_owner_aggregate(map_markers_cache_key, expires_in: 5.minutes, race_condition_ttl: 10.seconds) {
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
    if action_name == "show" && PhotoLocation.legacy_place_id?(params[:location_id])
      return redirect_to location_path(params[:location_id])
    end

    @albums = PhotoAlbum.visible_to(current_user).display_order
    @selected_album = @albums.find_by(id: params[:album_id]) if params[:album_id].present?
    if action_name == "markers"
      @map_locations = []
      @selected_location = selected_location_from_param(include_summary: false)
      @map_return_path = map_path(map_filter_params)
      return
    end

    @map_locations = map_location_options
    @selected_location = @map_locations.find { |location| location.id == params[:location_id].to_s } if params[:location_id].present?
    @selected_location ||= selected_location_from_param
    @map_locations << @selected_location if @selected_location && @map_locations.none? { |location| location.id == @selected_location.id }
    title_counts = @map_locations.map(&:title).tally
    @map_location_labels = @map_locations.to_h do |location|
      label = location.title
      label = "#{label} (#{PhotoLocation.title_for(location.latitude, location.longitude)})" if title_counts[label] > 1
      [ location.id, label ]
    end
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
      .merge(PhotoMetadata.geotagged)

    return PhotoLocation.scope_for(scope, @selected_location.id) if @selected_location

    params[:location_id].present? ? scope.none : scope
  end

  def marker_payload(photo)
    metadata = photo.display_metadata
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
    latitude_bucket_sql = PhotoLocation.latitude_bucket_sql(cell_size: cell_size)
    longitude_bucket_sql = PhotoLocation.longitude_bucket_sql(cell_size: cell_size)
    cluster_key_sql = "'cell:' || #{latitude_bucket_sql}::bigint::text || '_' || #{longitude_bucket_sql}::bigint::text"
    region_select_sql = "'cell' AS grouping_kind, NULL::text AS map_region_name"
    if region_rollup?
      scope = scope.left_outer_joins(metadata: :photo_place)
      known_region_sql = "NULLIF(photo_places.map_region_key, '') IS NOT NULL AND NULLIF(photo_places.map_region_name, '') IS NOT NULL"
      cluster_key_sql = "CASE WHEN #{known_region_sql} THEN 'region:' || photo_places.map_region_key ELSE #{cluster_key_sql} END"
      region_select_sql = <<~SQL.squish
        MIN(CASE WHEN #{known_region_sql} THEN 'region' ELSE 'cell' END) AS grouping_kind,
        MIN(CASE WHEN #{known_region_sql} THEN photo_places.map_region_name END) AS map_region_name
      SQL
    end
    location_id_sql = PhotoLocation.location_id_sql
    bucket_sql = <<~SQL.squish
      #{cluster_key_sql} AS cluster_key,
      #{region_select_sql},
      COUNT(DISTINCT #{location_id_sql}) AS location_count,
      MIN(#{location_id_sql}) AS location_id,
      MIN(photo_metadata.photo_place_id) AS photo_place_id,
      #{CLUSTER_SELECT_SQL}
    SQL

    scope
      .select(bucket_sql)
      .group(Arel.sql(cluster_key_sql))
      .order(Arel.sql("photo_count DESC, cluster_key ASC"))
      .limit(MARKER_LIMIT + 1)
  end

  def preview_photos(rows)
    ids = rows.first(MARKER_LIMIT).flat_map { |row| Array(row.preview_photo_ids).map(&:to_i) }
    Photo.includes(:display_metadata, :video_preview_attachment).where(id: ids).index_by(&:id)
  end

  def location_payload(row, count, photos_by_id, places)
    single_location = row.location_count.to_i == 1
    region = row.grouping_kind == "region"
    title = if region
      row.map_region_name
    elsif single_location
      places[row.photo_place_id.to_i] || PhotoLocation.title_for(row.latitude, row.longitude)
    else
      "#{row.location_count} nearby locations"
    end

    {
      type: "location",
      id: "location-#{row.cluster_key}",
      title: title,
      count: count,
      latitude: row.latitude.to_f,
      longitude: row.longitude.to_f,
      location_url: (location_path(row.location_id) if single_location && !region),
      zoom_to: (REGION_MAX_ZOOM + 1 if region),
      preview_urls: Array(row.preview_photo_ids)
        .filter_map { |id| photos_by_id[id.to_i] }
        .filter_map { |photo| map_media_url(photo) }
    }.compact
  end

  def map_media_url(photo)
    return stream_photo_path(photo) if photo.image?

    stream_photo_path(photo) if photo.video? && photo.video_preview.attached?
  end

  def location_places(rows)
    ids = rows.first(MARKER_LIMIT).filter_map do |row|
      row.photo_place_id if row.location_count.to_i == 1
    end

    PhotoPlace.where(id: ids.uniq).pluck(:id, :name).to_h
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

  def region_rollup?
    (bounded_float(params[:zoom], 1, 21) || 4) <= REGION_MAX_ZOOM
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
    return @selected_location.bounds.padded_bounds if @selected_location&.bounds && current_user&.owner?
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
      "map-markers/v7",
      cache_audience_key,
      @selected_album&.id || "all",
      @selected_location&.id || (params[:location_id].present? ? "invalid:#{params[:location_id]}" : "all"),
      Photo.maximum(:updated_at)&.utc&.to_i,
      PhotoMetadata.maximum(:updated_at)&.utc&.iso8601(6),
      PhotoPlace.maximum(:updated_at)&.utc&.iso8601(6),
      PhotoAlbumShare.maximum(:updated_at)&.utc&.to_i,
      PhotoAlbumShare.count,
      map_cell_size(params[:zoom]),
      region_rollup?,
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
    locations = PhotoLocation.groups(map_location_options_scope, limit: PhotoLocation::INDEX_LIMIT)
    bounds_by_id = PhotoLocationBound.where(location_id: locations.map(&:id)).index_by(&:location_id)

    locations.each do |location|
      location.bounds = bounds_by_id[location.id]
    end.sort_by { |location| location.title.to_s.downcase }
  end

  def selected_location_from_param(include_summary: true)
    location_id = params[:location_id].to_s
    return if location_id.blank? || !PhotoLocation.valid_id?(location_id)

    scope = PhotoLocation.scope_for(map_location_options_scope, location_id)
    return unless scope.exists?
    if PhotoLocation.legacy_place_id?(location_id)
      location_id = PhotoLocation.groups(scope, limit: 1).first&.id
      return unless location_id
    end
    return PhotoLocationGroup.new(id: location_id) unless include_summary

    location = if PhotoLocation.place_record_id?(location_id)
      PhotoLocation.groups(scope, limit: 1).first
    else
      latitude, longitude = scope.pick(Arel.sql("AVG(photo_metadata.latitude)"), Arel.sql("AVG(photo_metadata.longitude)"))
      PhotoLocationGroup.new(
        id: location_id, title: PhotoLocation.title_for(latitude, longitude),
        latitude: latitude, longitude: longitude, photo_count: scope.count
      )
    end
    location.bounds = PhotoLocationBound.find_by(location_id: location_id) if location
    location
  end

  def map_location_options_scope
    scope = @selected_album ? @selected_album.photos : Photo
    scope
      .visible_to(current_user)
      .joins(:metadata)
      .merge(PhotoMetadata.geotagged)
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
