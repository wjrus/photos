require "base64"

class PhotoLocation
  CELL_SIZE = 0.025
  INDEX_LIMIT = 500
  PLACE_ID_PREFIX = "place-".freeze
  BUCKET_FILTER_SQL = <<~SQL.squish.freeze
    (photo_metadata.latitude >= :south AND photo_metadata.latitude < :north
      AND photo_metadata.longitude >= :west AND photo_metadata.longitude < :east)
  SQL
  SELECT_SQL = <<~SQL.squish
    FLOOR(photo_metadata.latitude / :cell_size) AS latitude_bucket,
    FLOOR(photo_metadata.longitude / :cell_size) AS longitude_bucket,
    COUNT(*) AS photo_count,
    COUNT(*) FILTER (WHERE photos.content_type LIKE 'image/%') AS image_count,
    COUNT(*) FILTER (WHERE photos.content_type LIKE 'video/%') AS video_count,
    AVG(photo_metadata.latitude) AS latitude,
    AVG(photo_metadata.longitude) AS longitude,
    MAX(COALESCE(photos.captured_at, photos.created_at)) AS newest_at,
    MIN(COALESCE(photos.captured_at, photos.created_at)) AS oldest_at,
    (ARRAY_AGG(photos.id ORDER BY COALESCE(photos.captured_at, photos.created_at) DESC, photos.id DESC))[1] AS representative_photo_id
  SQL

  def self.rows(scope, limit: INDEX_LIMIT)
    bucket_select_sql = Photo.sanitize_sql_array([ SELECT_SQL, { cell_size: CELL_SIZE } ])

    scope
      .select(bucket_select_sql)
      .group(Arel.sql(latitude_bucket_sql), Arel.sql(longitude_bucket_sql))
      .order(Arel.sql("photo_count DESC, newest_at DESC"))
      .limit(limit)
  end

  def self.scope_for(scope, id)
    if place_id?(id)
      return scope_for_place_name(scope, place_name_from_id(id))
    end

    latitude_bucket, longitude_bucket = parse_id(id)
    return scope.none unless latitude_bucket && longitude_bucket

    scope.where(BUCKET_FILTER_SQL, bucket_bounds(latitude_bucket, longitude_bucket))
  end

  def self.scope_for_place_name(scope, name)
    scope_for_ids(scope, PhotoLocationPlace.where(name: name).pluck(:location_id))
  end

  def self.scope_for_ids(scope, ids)
    bucket_pairs = ids.filter_map do |location_id|
      latitude_bucket, longitude_bucket = parse_id(location_id)
      [ latitude_bucket, longitude_bucket ] if latitude_bucket && longitude_bucket
    end
    return scope.none if bucket_pairs.empty?

    conditions = bucket_pairs.uniq.map do |latitude_bucket, longitude_bucket|
      Photo.sanitize_sql_array([ BUCKET_FILTER_SQL, bucket_bounds(latitude_bucket, longitude_bucket) ])
    end
    scope.where(conditions.join(" OR "))
  end

  def self.bucket_bounds(latitude_bucket, longitude_bucket)
    # Half-open decimal ranges preserve FLOOR's buckets and allow the coordinate index to seek.
    cell_size = CELL_SIZE.to_d
    {
      south: latitude_bucket * cell_size, north: (latitude_bucket + 1) * cell_size,
      west: longitude_bucket * cell_size, east: (longitude_bucket + 1) * cell_size
    }
  end
  private_class_method :bucket_bounds

  def self.id_for(latitude_bucket, longitude_bucket)
    "#{latitude_bucket.to_i}_#{longitude_bucket.to_i}"
  end

  def self.parse_id(id)
    latitude_bucket, longitude_bucket = id.to_s.split("_", 2).map { |part| Integer(part) }
    [ latitude_bucket, longitude_bucket ]
  rescue ArgumentError, TypeError
    [ nil, nil ]
  end

  def self.valid_id?(id)
    return place_name_from_id(id).present? if place_id?(id)

    parse_id(id).all?
  end

  def self.place_id?(id)
    id.to_s.start_with?(PLACE_ID_PREFIX)
  end

  def self.place_id_for_name(name)
    "#{PLACE_ID_PREFIX}#{Base64.urlsafe_encode64(utf8_place_name(name), padding: false)}"
  end

  def self.place_name_from_id(id)
    return unless place_id?(id)

    encoded = id.to_s.delete_prefix(PLACE_ID_PREFIX)
    utf8_place_name(Base64.urlsafe_decode64(encoded))
  rescue ArgumentError
    nil
  end

  def self.title_for(latitude, longitude)
    "#{format_coordinate(latitude)}, #{format_coordinate(longitude)}"
  end

  def self.title_for_row(row, places = {})
    location_id = id_for_coordinates(row.latitude, row.longitude)
    places[location_id]&.name.presence || title_for(row.latitude, row.longitude)
  end

  def self.id_for_coordinates(latitude, longitude)
    id_for((latitude.to_f / CELL_SIZE).floor, (longitude.to_f / CELL_SIZE).floor)
  end

  def self.coordinate_id_sql
    # Match the Float conversion used for persisted place IDs, including boundary rounding.
    Photo.sanitize_sql_array([
      <<~SQL.squish,
        FLOOR(COALESCE(photo_metadata.latitude, 0)::double precision / :cell_size::double precision)::bigint::text
        || '_' ||
        FLOOR(COALESCE(photo_metadata.longitude, 0)::double precision / :cell_size::double precision)::bigint::text
      SQL
      { cell_size: CELL_SIZE }
    ])
  end

  def self.latitude_bucket_sql
    @latitude_bucket_sql ||= Photo.sanitize_sql_array([ "FLOOR(photo_metadata.latitude / :cell_size)", { cell_size: CELL_SIZE } ])
  end

  def self.longitude_bucket_sql
    @longitude_bucket_sql ||= Photo.sanitize_sql_array([ "FLOOR(photo_metadata.longitude / :cell_size)", { cell_size: CELL_SIZE } ])
  end

  def self.format_coordinate(value)
    format("%.4f", value.to_f)
  end

  def self.utf8_place_name(value)
    value.to_s.dup.force_encoding(Encoding::UTF_8).scrub
  end
  private_class_method :utf8_place_name
end
