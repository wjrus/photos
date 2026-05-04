class HomeController < ApplicationController
  include PhotoStreamPagination

  def show
    @photos, @next_cursor = paginate_photo_stream(Photo.with_original_variant_records.visible_to(current_user).stream_order)
    @albums = current_user.photo_albums.display_order if current_user&.owner?

    render_photo_page_if_requested(
      return_to: root_path,
      bulk_form_id: "photo-bulk-form",
      next_page_path: root_path
    )
  end
end
