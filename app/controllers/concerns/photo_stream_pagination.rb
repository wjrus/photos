module PhotoStreamPagination
  extend ActiveSupport::Concern

  private

  def paginate_photo_stream(scope)
    photos = scope.before_stream_cursor(params[:cursor]).limit(Photo::STREAM_PAGE_SIZE + 1).to_a
    next_photo = photos[Photo::STREAM_PAGE_SIZE]

    [ photos.first(Photo::STREAM_PAGE_SIZE), next_photo&.stream_cursor ]
  end

  def render_photo_page_if_requested(**locals)
    return unless params[:cursor].present?

    render partial: "photos/page", locals: photo_page_locals(**locals)
  end

  def photo_page_locals(return_to:, next_page_path:, bulk_form_id:, feature_first: false, owner_controls: current_user&.owner?, **extras)
    {
      photos: @photos,
      return_to: return_to,
      feature_first: feature_first,
      bulk_form_id: bulk_form_id,
      owner_controls: owner_controls,
      next_cursor: @next_cursor,
      next_page_path: next_page_path
    }.merge(extras)
  end
end
