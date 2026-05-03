class ArchivedPhotosController < ApplicationController
  include PhotoStreamPagination

  before_action :require_owner!

  def index
    @photos, @next_cursor = paginate_photo_stream(current_user.photos
      .archived
      .with_original_variant_records
      .stream_order)
    @albums = current_user.photo_albums.display_order

    render partial: "photos/page", locals: photo_page_locals(feature_first: false) if params[:cursor].present?
  end

  private

  def photo_page_locals(feature_first:)
    {
      photos: @photos,
      return_to: archived_photos_path,
      feature_first: feature_first,
      bulk_form_id: "archive-photo-bulk-form",
      owner_controls: true,
      archive_context: true,
      next_cursor: @next_cursor,
      next_page_path: archived_photos_path
    }
  end

  def require_owner!
    return if current_user&.owner?

    redirect_to root_path, alert: "Only the owner can open the archive."
  end
end
