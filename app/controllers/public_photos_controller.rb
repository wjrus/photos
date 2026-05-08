class PublicPhotosController < ApplicationController
  include PhotoStreamPagination

  owner_access_message "Only the owner can open the public stream."

  before_action :require_owner!

  def index
    public_stream = current_user.photos.publicly_visible
    stream_scope = public_stream.with_original_variant_records.stream_order
    @photos, @next_cursor, @newer_cursor = paginate_photo_stream_with_focus(stream_scope)
    @newer_cursor ||= timeline_newer_cursor(public_stream) if params[:timeline_page].present?

    return if render_photo_page_if_requested(
      return_to: public_photos_path,
      bulk_form_id: "public-photo-bulk-form",
      next_page_path: public_photos_path,
      stream_target_photo_id: @stream_target_photo_id
    )

    @albums = current_user.photo_albums.display_order
    @timeline_periods = stream_timeline_periods(public_stream, cache_key: public_timeline_cache_key) unless params[:cursor].present?
  end

  private

  def public_timeline_cache_key
    [
      "public-stream-timeline/v1",
      current_user.id,
      current_user.photos.publicly_visible.maximum(:updated_at)&.utc&.to_i,
      current_user.photos.publicly_visible.count
    ]
  end
end
