class PhotoLocation
  CELL_SIZE = 0.025
  INDEX_LIMIT = 500
  SELECT_SQL = <<~SQL.squish
    FLOOR(photo_metadata.latitude / :cell_size) AS latitude_bucket,
    FLOOR(photo_metadata.longitude / :cell_size) AS longitude_bucket,
    COUNT(*) AS photo_count,
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
    latitude_bucket, longitude_bucket = parse_id(id)

    scope
      .where("FLOOR(photo_metadata.latitude / ?) = ?", CELL_SIZE, latitude_bucket)
      .where("FLOOR(photo_metadata.longitude / ?) = ?", CELL_SIZE, longitude_bucket)
  end

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
    parse_id(id).all?
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

  def self.latitude_bucket_sql
    @latitude_bucket_sql ||= Photo.sanitize_sql_array([ "FLOOR(photo_metadata.latitude / :cell_size)", { cell_size: CELL_SIZE } ])
  end

  def self.longitude_bucket_sql
    @longitude_bucket_sql ||= Photo.sanitize_sql_array([ "FLOOR(photo_metadata.longitude / :cell_size)", { cell_size: CELL_SIZE } ])
  end

  def self.format_coordinate(value)
    format("%.4f", value.to_f)
  end
end
