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
      timeline_scope = scope.except(:order).where.not(captured_at: nil)
      oldest_at, newest_at = timeline_scope.pick(
        Arel.sql("MIN(photos.captured_at)"),
        Arel.sql("MAX(photos.captured_at)")
      )
      next [] unless oldest_at && newest_at

      precision = stream_timeline_precision(oldest_at, newest_at)
      period_sql = stream_timeline_period_sql(precision)

      timeline_scope
        .group(period_sql)
        .order(stream_timeline_period_order_sql(precision))
        .count
        .map do |period, count|
          period = stream_timeline_period_start(period, precision)
          {
            period: period,
            precision: precision,
            count: count,
            label: stream_timeline_label(period, precision),
            marker_label: stream_timeline_marker_label(period, precision),
            year: period.year,
            month: period.month,
            key: stream_timeline_key(period, precision),
            cursor: Photo.stream_cursor_before(stream_timeline_next_period(period, precision))
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

  def stream_timeline_precision(oldest_at, newest_at)
    span = newest_at - oldest_at

    return "hour" if span <= 36.hours
    return "day" if span <= 45.days

    "month"
  end

  def stream_timeline_period_sql(precision)
    case precision
    when "hour" then Arel.sql("DATE_TRUNC('hour', photos.captured_at)")
    when "day" then Arel.sql("DATE_TRUNC('day', photos.captured_at)")
    else Arel.sql("DATE_TRUNC('month', photos.captured_at)")
    end
  end

  def stream_timeline_period_order_sql(precision)
    case precision
    when "hour" then Arel.sql("DATE_TRUNC('hour', photos.captured_at) DESC")
    when "day" then Arel.sql("DATE_TRUNC('day', photos.captured_at) DESC")
    else Arel.sql("DATE_TRUNC('month', photos.captured_at) DESC")
    end
  end

  def stream_timeline_period_start(period, precision)
    time = period.in_time_zone

    case precision
    when "hour" then time.beginning_of_hour
    when "day" then time.beginning_of_day
    else time.beginning_of_month
    end
  end

  def stream_timeline_next_period(period, precision)
    case precision
    when "hour" then period + 1.hour
    when "day" then period.next_day
    else period.next_month
    end
  end

  def stream_timeline_key(period, precision)
    case precision
    when "hour" then period.strftime("%Y-%m-%dT%H")
    when "day" then period.strftime("%Y-%m-%d")
    else period.strftime("%Y-%m")
    end
  end

  def stream_timeline_label(period, precision)
    case precision
    when "hour" then period.strftime("%b %-d, %Y, %-l %p")
    when "day" then period.strftime("%B %-d, %Y")
    else period.strftime("%B %Y")
    end
  end

  def stream_timeline_marker_label(period, precision)
    case precision
    when "hour" then period.strftime("%-l %p")
    when "day" then period.strftime("%b %-d")
    else period.year.to_s
    end
  end
end
