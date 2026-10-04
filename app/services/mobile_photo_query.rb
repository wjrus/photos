class MobilePhotoQuery
  attr_reader :order

  def initialize(scope:, user:, params:)
    @scope, @user, @params = scope, user, params
    (PhotoSearch::FILTER_PARAMS + %i[cursor order direction album_id media_type captured_after captured_before]).each do |key|
      value = params[key]
      raise ActionController::BadRequest if value && !value.is_a?(String) && !value.is_a?(Numeric)
    end
    @order = params[:order].presence || (params[:album_id].present? ? "chronological" : "stream")
    raise ActionController::BadRequest unless %w[stream chronological].include?(@order)
  end

  def scope
    result = @scope
    if @params[:album_id].present?
      album = PhotoAlbum.visible_to(@user).find(@params[:album_id])
      result = result.where(id: album.photo_album_memberships.select(:photo_id))
    end
    filters = @params.permit(*PhotoSearch::FILTER_PARAMS).to_h
    raise ActionController::BadRequest if filters.values.any? { |value| value.to_s.bytesize > 500 }
    if filters.values.any?(&:present?)
      search = PhotoSearch.new(params: filters, user: @user, semantic: false, scope: result)
      result = result.where(id: search.results.except(:includes, :order).select(:id))
    end
    case @params[:media_type].presence
    when "image" then result = result.still_images
    when "video" then result = result.where("photos.content_type LIKE ?", "video/%")
    when nil
    else raise ActionController::BadRequest
    end
    result = result.where(captured_at: Time.iso8601(@params[:captured_after])..) if @params[:captured_after].present?
    result = result.where(captured_at: ...Time.iso8601(@params[:captured_before])) if @params[:captured_before].present?
    result
  end

  def page(limit:)
    direction = @params[:direction].presence || "next"
    raise ActionController::BadRequest unless %w[next previous].include?(direction)
    cursor = @params[:cursor]
    if cursor.present?
      raise ActionController::BadRequest unless cursor.is_a?(String) && cursor.bytesize <= 150 && Photo.decode_stream_cursor(cursor).last.present?
    end
    result = scope
    result = following(result, cursor, direction: direction) if cursor.present?
    result = ordered(result, reverse: direction == "previous")
    rows = result.includes(:display_metadata, :original_attachment, :video_preview_attachment, :video_display_attachment).limit(limit + 1).to_a
    has_more = rows.size > limit
    rows = rows.first(limit)
    rows.reverse! if direction == "previous"
    { photos: rows, has_more: has_more, next_cursor: rows.last&.stream_cursor,
      previous_cursor: rows.first&.stream_cursor, direction: direction, order: order }
  end

  def neighbors(photo)
    { previous: ordered(following(scope, photo.stream_cursor, direction: "previous"), reverse: true).first,
      next: ordered(following(scope, photo.stream_cursor, direction: "next")).first }
  end

  private

  def following(scope, cursor, direction:)
    if order == "chronological"
      direction == "previous" ? scope.before_chronological_cursor(cursor) : scope.after_chronological_cursor(cursor)
    else
      direction == "previous" ? scope.after_stream_cursor(cursor) : scope.before_stream_cursor(cursor)
    end
  end

  def ordered(scope, reverse: false)
    if order == "chronological"
      reverse ? scope.reverse_chronological_order : scope.chronological_order
    else
      reverse ? scope.reverse_stream_order : scope.reorder(Arel.sql(Photo.stream_tuple_order(direction: "DESC")))
    end
  end
end
