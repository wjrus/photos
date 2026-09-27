class LocationsController < ApplicationController
  include PhotoStreamPagination

  LOCATION_PAGE_SIZE = 12

  before_action :require_privileged_metadata_viewer!
  before_action :set_location, only: :show

  def index
    @location_count = cache_owner_aggregate([ location_index_cache_key, "count" ], expires_in: 12.hours) do
      PhotoLocation.group_count(geotagged_photos)
    end
    @location_page = [ params[:page].to_i, 1 ].max
    offset = (@location_page - 1) * LOCATION_PAGE_SIZE
    @locations = offset < @location_count ? cached_location_rows(offset: offset) : []
    @next_location_page = @location_page + 1 if @location_page * LOCATION_PAGE_SIZE < @location_count
    @location_covers = location_covers(@locations)

    render partial: "locations/page", locals: { locations: @locations }, layout: false if @location_page > 1
  end

  def show
    scoped_photos = location_photo_scope
    stream_scope = scoped_photos
      .with_original_variant_records
      .stream_order
    @photos, @next_cursor, @newer_cursor = paginate_photo_stream_with_focus(stream_scope)
    @newer_cursor ||= timeline_newer_cursor(scoped_photos) if params[:timeline_page].present?
    if @photos.empty? && !scoped_photos.exists?
      raise ActiveRecord::RecordNotFound
    end

    return if render_photo_page_if_requested(
      return_to: location_path(@location_id),
      bulk_form_id: "location-photo-bulk-form",
      group_by_day: false,
      next_page_path: location_path(@location_id),
      stream_target_photo_id: @stream_target_photo_id
    )

    set_location_summary
    @location_media_count = media_counts_for(scoped_photos)
    @location_map_path = map_path(location_map_bounds_params(scoped_photos).merge(location_id: @location_id))
    @albums = current_user.photo_albums.display_order if current_user&.owner?
    @timeline_periods = stream_timeline_periods(scoped_photos, cache_key: location_timeline_cache_key(scoped_photos)) unless params[:cursor].present?
  end

  private

  def cached_location_rows(offset:)
    cache_owner_aggregate([ location_index_cache_key, offset ], expires_in: 12.hours, race_condition_ttl: 2.minutes) do
      PhotoLocation.groups(geotagged_photos, limit: LOCATION_PAGE_SIZE, offset: offset)
    end
  end

  def location_index_cache_key
    [
      "locations-index/v4",
      cache_audience_key,
      Photo.maximum(:updated_at)&.utc&.to_i,
      PhotoMetadata.maximum(:updated_at)&.utc&.iso8601(6),
      PhotoPlace.maximum(:updated_at)&.utc&.iso8601(6),
      PhotoMetadata.count,
      PhotoAlbumShare.maximum(:updated_at)&.utc&.to_i,
      PhotoAlbumShare.count,
      PhotoLocationCover.maximum(:updated_at)&.utc&.to_i,
      PhotoLocationCover.count
    ]
  end

  def location_timeline_cache_key(scoped_photos)
    [
      "location-timeline/v5",
      cache_audience_key,
      @location_id,
      Photo.maximum(:updated_at)&.utc&.to_i,
      PhotoMetadata.maximum(:updated_at)&.utc&.iso8601(6),
      PhotoAlbumShare.maximum(:updated_at)&.utc&.to_i,
      PhotoAlbumShare.count,
      stream_timeline_cache_fingerprint(scoped_photos)
    ]
  end

  def geotagged_photos
    Photo
      .visible_to(current_user)
      .joins(:metadata)
      .merge(PhotoMetadata.geotagged)
  end

  def location_covers(locations)
    fallback_cover_ids = locations.map { |location| location.representative_photo_id.to_i }
    explicit_covers = explicit_location_covers(locations)
    cover_ids = (fallback_cover_ids + explicit_covers.values).uniq

    photos = Photo
      .with_original_variant_records
      .visible_to(current_user)
      .where(id: cover_ids)
      .index_by(&:id)

    locations.each_with_object({}) do |location, covers|
      candidates = [ photos[explicit_covers[location.id]], photos[location.representative_photo_id.to_i] ].compact
      cover = candidates.find { |photo| PhotoLocation.id_for_metadata(photo.display_metadata) == location.id }
      covers[location.id] = cover if cover
    end
  end

  def explicit_location_covers(locations)
    aliases = locations.to_h do |location|
      legacy_id = if PhotoLocation.area_id?(location.id)
        location.id.delete_prefix(PhotoLocation::AREA_ID_PREFIX)
      else
        PhotoLocation.place_id_for_name(location.title)
      end
      [ location.id, legacy_id ]
    end
    covers = PhotoLocationCover
      .where(location_id: aliases.keys + aliases.values)
      .pluck(:location_id, :cover_photo_id)
      .to_h
    aliases.to_h { |id, legacy_id| [ id, covers[id] || covers[legacy_id] ] }
  end

  def set_location
    @location_id = params[:id].to_s
    raise ActiveRecord::RecordNotFound unless PhotoLocation.valid_id?(@location_id)
    return unless PhotoLocation.legacy_place_id?(@location_id)

    candidates = PhotoLocation.legacy_groups(geotagged_photos, @location_id)
    raise ActiveRecord::RecordNotFound if candidates.empty?
    return redirect_to location_path(candidates.first.id) if candidates.one?

    @legacy_place_name = PhotoLocation.place_name_from_id(@location_id)
    @locations = candidates
    @location_count = candidates.size
    @location_covers = location_covers(candidates)
    render :index
  end

  def set_location_summary
    if PhotoLocation.place_record_id?(@location_id)
      @location_title = PhotoLocation.place_name_from_id(@location_id)
      @location_photo_count = location_photo_scope.count
    else
      @location_row = PhotoLocation.rows(location_photo_scope, limit: 1).first
      raise ActiveRecord::RecordNotFound unless @location_row

      @location_title = PhotoLocation.title_for(@location_row.latitude, @location_row.longitude)
      @location_photo_count = @location_row.photo_count.to_i
    end
  end

  def location_photo_scope
    PhotoLocation.scope_for(geotagged_photos, @location_id)
  end

  def media_counts_for(scope)
    counts = scope
      .reselect(
        "COUNT(*) FILTER (WHERE photos.content_type LIKE 'image/%') AS image_count",
        "COUNT(*) FILTER (WHERE photos.content_type LIKE 'video/%') AS video_count"
      )
      .take

    { photos: counts.image_count.to_i, videos: counts.video_count.to_i }
  end

  def location_map_bounds_params(scope)
    bounds = location_bounds(scope)
    return {} unless bounds

    bounds.transform_values { |value| format("%.6f", value) }
  end

  def location_bounds(scope)
    cached_bounds = PhotoLocationBound.find_by(location_id: @location_id)
    return cached_bounds.padded_bounds if cached_bounds && current_user&.owner?

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

  def require_privileged_metadata_viewer!
    return if privileged_metadata_viewer?

    redirect_to root_path, alert: "Only trusted viewers can browse locations."
  end
end
