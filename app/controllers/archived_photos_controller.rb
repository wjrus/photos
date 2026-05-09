class ArchivedPhotosController < ApplicationController
  include PhotoStreamPagination
  owner_access_message "Only the owner can open the archive."

  before_action :require_owner!

  def index
    archive_stream = current_user.photos.archived
    stream_scope = archive_stream.with_original_variant_records.stream_order
    @photos, @next_cursor, @newer_cursor = paginate_photo_stream_with_focus(stream_scope)
    @newer_cursor ||= timeline_newer_cursor(archive_stream) if params[:timeline_page].present?

    return if render_photo_page_if_requested(
      return_to: archived_photos_path,
      bulk_form_id: "archive-photo-bulk-form",
      owner_controls: true,
      archive_context: true,
      next_page_path: archived_photos_path,
      stream_target_photo_id: @stream_target_photo_id
    )

    @albums = current_user.photo_albums.display_order
    @timeline_periods = stream_timeline_periods(archive_stream, cache_key: archive_timeline_cache_key) unless params[:cursor].present?
  end

  private

  def archive_timeline_cache_key
    [
      "archive-stream-timeline/v1",
      current_user.id,
      current_user.photos.archived.maximum(:updated_at)&.utc&.to_i,
      current_user.photos.archived.count
    ]
  end
end
