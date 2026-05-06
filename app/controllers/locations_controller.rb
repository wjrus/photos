class LocationsController < ApplicationController
  include PhotoStreamPagination

  before_action :require_privileged_metadata_viewer!
  before_action :set_location, only: :show

  def index
    location_rows = cached_location_rows
    @location_places = location_places(location_rows)
    @locations = grouped_location_rows(location_rows, @location_places)
    @location_covers = location_covers(@locations)
  end

  def show
    @photos, @next_cursor, = paginate_photo_stream(location_photo_scope
      .with_original_variant_records
      .stream_order)
    @location_media_count = media_counts_for(location_photo_scope)
    @albums = current_user.photo_albums.display_order if current_user&.owner?

    render_photo_page_if_requested(
      return_to: location_path(@location_id),
      bulk_form_id: "location-photo-bulk-form",
      group_by_day: false,
      next_page_path: location_path(@location_id)
    )
  end

  private

  def cached_location_rows
    Rails.cache.fetch(location_index_cache_key, expires_in: 12.hours, race_condition_ttl: 2.minutes) do
      PhotoLocation.rows(geotagged_photos).to_a
    end
  end

  def location_index_cache_key
    [
      "locations-index/v2",
      cache_audience_key,
      Photo.maximum(:updated_at)&.utc&.to_i,
      PhotoMetadata.maximum(:updated_at)&.utc&.to_i,
      PhotoMetadata.count,
      PhotoLocationCover.maximum(:updated_at)&.utc&.to_i,
      PhotoLocationCover.count
    ]
  end

  def geotagged_photos
    Photo
      .visible_to(current_user)
      .joins(:metadata)
      .where.not(photo_metadata: { latitude: nil, longitude: nil })
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
      cover = photos[explicit_covers[location.id]] || photos[location.representative_photo_id.to_i]
      covers[location.id] = cover if cover
    end
  end

  def explicit_location_covers(locations)
    PhotoLocationCover
      .where(location_id: locations.map(&:id))
      .pluck(:location_id, :cover_photo_id)
      .to_h
  end

  def set_location
    @location_id = params[:id].to_s
    raise ActiveRecord::RecordNotFound unless PhotoLocation.valid_id?(@location_id)

    if PhotoLocation.place_id?(@location_id)
      @location_title = PhotoLocation.place_name_from_id(@location_id)
      @location_photo_count = location_photo_scope.count
    else
      @location_row = PhotoLocation.rows(location_photo_scope, limit: 1).first
      raise ActiveRecord::RecordNotFound unless @location_row

      @location_places = location_places([ @location_row ])
      enqueue_missing_location_names([ @location_row ], @location_places)
      @location_title = PhotoLocation.title_for_row(@location_row, @location_places)
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

  def location_places(locations)
    ids = locations.map do |location|
      if location.respond_to?(:location_ids)
        location.location_ids
      else
        PhotoLocation.id_for_coordinates(location.latitude, location.longitude)
      end
    end.flatten

    PhotoLocationPlace.where(location_id: ids).index_by(&:location_id)
  end

  def grouped_location_rows(locations, places)
    groups = {}

    locations.each do |location|
      location_id = PhotoLocation.id_for(location.latitude_bucket, location.longitude_bucket)
      place_name = places[location_id]&.name.presence
      group_id = place_name ? PhotoLocation.place_id_for_name(place_name) : location_id
      title = place_name || PhotoLocation.title_for_row(location, places)

      groups[group_id] ||= PhotoLocationGroup.new(id: group_id, title: title)
      groups[group_id].add(location)
    end

    groups.values.sort_by { |location| [ -location.photo_count.to_i, -(location.newest_at&.to_i || 0) ] }
  end

  def enqueue_missing_location_names(locations, places)
    return unless LocationReverseGeocoder.api_key.present?

    locations.each do |location|
      location_id = PhotoLocation.id_for_coordinates(location.latitude, location.longitude)
      next if places[location_id]

      GeocodePhotoLocationJob.perform_later(location_id, location.latitude, location.longitude)
    end
  end

  def require_privileged_metadata_viewer!
    return if privileged_metadata_viewer?

    redirect_to root_path, alert: "Only trusted viewers can browse locations."
  end
end
