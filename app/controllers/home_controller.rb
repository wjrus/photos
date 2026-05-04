class HomeController < ApplicationController
  include PhotoStreamPagination

  def show
    visible_stream = Photo.visible_to(current_user)
    @photos, @next_cursor = paginate_photo_stream(visible_stream.with_original_variant_records.stream_order)
    @albums = current_user.photo_albums.display_order if current_user&.owner?
    @timeline_periods = stream_timeline_periods(visible_stream) unless params[:cursor].present?

    render_photo_page_if_requested(
      return_to: root_path,
      bulk_form_id: "photo-bulk-form",
      next_page_path: root_path
    )
  end

  private

  def stream_timeline_periods(scope)
    Rails.cache.fetch(stream_timeline_cache_key, expires_in: 30.minutes, race_condition_ttl: 10.seconds) do
      scope
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
            key: period.strftime("%Y-%m")
          }
        end
    end
  end

  def stream_timeline_cache_key
    [
      "stream-timeline/v2",
      cache_audience_key,
      Photo.maximum(:updated_at)&.utc&.to_i,
      Photo.count
    ]
  end
end
