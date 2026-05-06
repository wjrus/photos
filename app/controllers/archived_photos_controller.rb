class ArchivedPhotosController < ApplicationController
  include PhotoStreamPagination
  owner_access_message "Only the owner can open the archive."

  before_action :require_owner!

  def index
    @photos, @next_cursor, @newer_cursor = paginate_photo_stream_with_focus(current_user.photos
      .archived
      .with_original_variant_records
      .stream_order)
    @albums = current_user.photo_albums.display_order

    render_photo_page_if_requested(
      return_to: archived_photos_path,
      bulk_form_id: "archive-photo-bulk-form",
      owner_controls: true,
      archive_context: true,
      next_page_path: archived_photos_path,
      stream_target_photo_id: @stream_target_photo_id
    )
  end
end
