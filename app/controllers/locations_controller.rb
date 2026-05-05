class LocationsController < ApplicationController
  include PhotoStreamPagination

  before_action :require_privileged_metadata_viewer!
  before_action :set_location, only: :show

  def index
    @locations = cached_location_rows
    @location_places = location_places(@locations)
    @location_covers = location_covers(@locations)
  end

  def show
    @photos, @next_cursor, = paginate_photo_stream(location_photo_scope
      .with_original_variant_records
      .stream_order)
    @albums = current_user.photo_albums.display_order if current_user&.owner?

    render_photo_page_if_requested(
      return_to: location_path(@location_id),
      bulk_form_id: "location-photo-bulk-form",
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
      "locations-index/v1",
      cache_audience_key,
      Photo.maximum(:updated_at)&.utc&.to_i,
      PhotoMetadata.maximum(:updated_at)&.utc&.to_i,
      PhotoMetadata.count
    ]
  end

  def geotagged_photos
    Photo
      .visible_to(current_user)
      .joins(:metadata)
      .where.not(photo_metadata: { latitude: nil, longitude: nil })
  end

  def location_covers(locations)
    cover_ids = locations.map { |location| location.representative_photo_id.to_i }

    Photo
      .with_original_variant_records
      .visible_to(current_user)
      .where(id: cover_ids)
      .index_by(&:id)
  end

  def set_location
    @location_id = params[:id].to_s
    raise ActiveRecord::RecordNotFound unless PhotoLocation.valid_id?(@location_id)

    @location_row = PhotoLocation.rows(location_photo_scope, limit: 1).first
    raise ActiveRecord::RecordNotFound unless @location_row

    @location_places = location_places([ @location_row ])
    enqueue_missing_location_names([ @location_row ], @location_places)
    @location_title = PhotoLocation.title_for_row(@location_row, @location_places)
  end

  def location_photo_scope
    PhotoLocation.scope_for(geotagged_photos, @location_id)
  end

  def location_places(locations)
    ids = locations.map { |location| PhotoLocation.id_for_coordinates(location.latitude, location.longitude) }
    PhotoLocationPlace.where(location_id: ids).index_by(&:location_id)
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
