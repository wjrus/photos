module PhotoStreamPagination
  extend ActiveSupport::Concern

  private

  def paginate_photo_stream(scope)
    photos = scope.before_stream_cursor(params[:cursor]).limit(Photo::STREAM_PAGE_SIZE + 1).to_a
    next_photo = photos[Photo::STREAM_PAGE_SIZE]

    [ photos.first(Photo::STREAM_PAGE_SIZE), next_photo&.stream_cursor ]
  end
end
