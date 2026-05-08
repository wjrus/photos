module PhotoStreamPagination
  extend ActiveSupport::Concern

  private

  def paginate_photo_stream(scope)
    return paginate_newer_photo_stream(scope) if params[:newer_cursor].present?

    photos = scope.before_stream_cursor(params[:cursor]).limit(Photo::STREAM_PAGE_SIZE + 1).to_a
    next_photo = photos[Photo::STREAM_PAGE_SIZE]

    [ photos.first(Photo::STREAM_PAGE_SIZE), next_photo&.stream_cursor, nil ]
  end

  def paginate_photo_stream_with_focus(scope)
    focused_photo = focused_stream_photo(scope)

    if focused_photo
      @stream_target_photo_id = focused_photo.id
      paginate_photo_stream_focused(scope, focused_photo)
    else
      paginate_photo_stream(scope)
    end
  end

  def paginate_photo_stream_focused(scope, photo)
    previous_photo = scope.stream_before(photo)
    page_scope = previous_photo ? scope.before_stream_cursor(previous_photo.stream_cursor) : scope
    photos = page_scope.limit(Photo::STREAM_PAGE_SIZE + 1).to_a
    next_photo = photos[Photo::STREAM_PAGE_SIZE]
    page = photos.first(Photo::STREAM_PAGE_SIZE)

    [ page, next_photo&.stream_cursor, (page.first&.stream_cursor if previous_photo) ]
  end

  def render_photo_page_if_requested(**locals)
    return false unless params[:cursor].present? || params[:newer_cursor].present? || params[:stream_page].present?

    render partial: "photos/page", locals: photo_page_locals(**locals)
    true
  end

  def stream_timeline_periods(scope, cache_key:)
    Rails.cache.fetch(cache_key, expires_in: 30.minutes, race_condition_ttl: 10.seconds) do
      scope
        .except(:order)
        .where.not(captured_at: nil)
        .group(Arel.sql("DATE_TRUNC('month', photos.captured_at)"))
        .order(Arel.sql("DATE_TRUNC('month', photos.captured_at) DESC"))
        .count
        .map do |period, count|
          period = period.in_time_zone.beginning_of_month
          {
            period: period,
            count: count,
            label: period.strftime("%B %Y"),
            year: period.year,
            month: period.month,
            key: period.strftime("%Y-%m"),
            cursor: Photo.stream_cursor_before(period.next_month)
          }
        end
    end
  end

  def timeline_newer_cursor(scope)
    cursor = @photos.first&.stream_cursor
    return unless cursor

    cursor if scope.after_stream_cursor(cursor).exists?
  end

  def photo_page_locals(return_to:, next_page_path:, bulk_form_id:, feature_first: false, owner_controls: current_user&.owner?, newer_cursor: @newer_cursor, **extras)
    {
      photos: @photos,
      return_to: return_to,
      feature_first: feature_first,
      bulk_form_id: bulk_form_id,
      owner_controls: owner_controls,
      next_cursor: @next_cursor,
      newer_cursor: newer_cursor,
      next_page_path: next_page_path,
      stream_target_photo_id: @stream_target_photo_id
    }.merge(extras)
  end

  def focused_stream_photo(scope)
    return if params[:photo_id].blank? || params[:stream_page].present? || params[:cursor].present? || params[:newer_cursor].present?

    scope.find_by(id: params[:photo_id])
  end

  def paginate_newer_photo_stream(scope)
    photos = scope
      .after_stream_cursor(params[:newer_cursor])
      .reverse_stream_order
      .limit(Photo::STREAM_PAGE_SIZE + 1)
      .to_a

    has_more = photos.size > Photo::STREAM_PAGE_SIZE
    page = photos.first(Photo::STREAM_PAGE_SIZE).reverse

    [ page, nil, (page.first.stream_cursor if has_more && page.any?) ]
  end
end
