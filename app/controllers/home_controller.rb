class HomeController < ApplicationController
  include PhotoStreamPagination

  def show
    @photos, @next_cursor = paginate_photo_stream(Photo.with_attached_original.visible_to(current_user).stream_order)
    @albums = current_user.photo_albums.display_order if current_user&.owner?

    render partial: "photos/page", locals: photo_page_locals(feature_first: false) if params[:cursor].present?
  end

  private

  def photo_page_locals(feature_first:)
    {
      photos: @photos,
      return_to: root_path,
      feature_first: feature_first,
      bulk_form_id: "photo-bulk-form",
      owner_controls: current_user&.owner?,
      next_cursor: @next_cursor,
      next_page_path: root_path
    }
  end
end
