class HomeController < ApplicationController
  include PhotoStreamPagination

  def show
    visible_stream = Photo.visible_to(current_user)
    stream_scope = visible_stream.with_original_variant_records.stream_order
    focused_photo = visible_stream.find_by(id: params[:photo_id]) if params[:photo_id].present? && !params[:stream_page].present?

    if focused_photo
      @stream_target_photo_id = focused_photo.id
      @photos, @next_cursor, @newer_cursor = paginate_photo_stream_focused(stream_scope, focused_photo)
    else
      @photos, @next_cursor, @newer_cursor = paginate_photo_stream(stream_scope)
    end

    @newer_cursor ||= timeline_newer_cursor(visible_stream) if params[:timeline_page].present?
    return if render_photo_page_if_requested(
      return_to: root_path,
      bulk_form_id: "photo-bulk-form",
      next_page_path: root_path,
      stream_target_photo_id: @stream_target_photo_id
    )

    @albums = current_user.photo_albums.display_order if current_user&.owner?
    @timeline_periods = stream_timeline_periods(visible_stream, cache_key: stream_timeline_cache_key) unless params[:cursor].present?
  end

  private

  def stream_timeline_cache_key
    [
      "stream-timeline/v3",
      cache_audience_key,
      Photo.maximum(:updated_at)&.utc&.to_i,
      Photo.count,
      PhotoAlbumShare.maximum(:updated_at)&.utc&.to_i,
      PhotoAlbumShare.count
    ]
  end
end
