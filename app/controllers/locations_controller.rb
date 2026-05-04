class LocationsController < ApplicationController
  include PhotoStreamPagination

  before_action :require_privileged_metadata_viewer!
  before_action :set_location, only: :show

  def index
    @locations = cached_location_rows
    @location_covers = location_covers(@locations)
  end

  def show
    @photos, @next_cursor = paginate_photo_stream(location_photo_scope
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
    Rails.cache.fetch(location_index_cache_key, expires_in: 10.minutes, race_condition_ttl: 10.seconds) do
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

    @location_title = PhotoLocation.title_for(@location_row.latitude, @location_row.longitude)
  end

  def location_photo_scope
    PhotoLocation.scope_for(geotagged_photos, @location_id)
  end

  def require_privileged_metadata_viewer!
    return if privileged_metadata_viewer?

    redirect_to root_path, alert: "Only trusted viewers can browse locations."
  end
end
