require "base64"

class PhotoLocation
  CELL_SIZE = 0.025
  COORDINATE_STEP = BigDecimal("0.000001")
  INDEX_LIMIT = 500
  PLACE_ID_PREFIX = "place-".freeze
  RECORD_ID_PREFIX = "place-id-".freeze
  AREA_ID_PREFIX = "area-".freeze
  BUCKET_FILTER_SQL = <<~SQL.squish.freeze
    (photo_metadata.latitude >= :south AND photo_metadata.latitude < :north
      AND photo_metadata.longitude >= :west AND photo_metadata.longitude < :east)
  SQL
  SELECT_SQL = <<~SQL.squish
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
    bucket_select_sql = "#{latitude_bucket_sql} AS latitude_bucket, #{longitude_bucket_sql} AS longitude_bucket, #{SELECT_SQL}"

    scope
      .select(bucket_select_sql)
      .group(Arel.sql(latitude_bucket_sql), Arel.sql(longitude_bucket_sql))
      .order(Arel.sql("photo_count DESC, newest_at DESC"))
      .limit(limit)
  end

  # Spatial cells are only the fallback for photos that have not been matched.
  # A resolved place can cross cells, and several distinct places can share one.
  def self.location_id_sql
    "CASE WHEN photo_metadata.photo_place_id IS NOT NULL THEN '#{RECORD_ID_PREFIX}' || photo_metadata.photo_place_id::text ELSE '#{AREA_ID_PREFIX}' || #{coordinate_id_sql} END"
  end

  def self.group_count(scope)
    scope.except(:order, :includes, :preload, :eager_load).distinct.count(Arel.sql(location_id_sql))
  end

  def self.groups(scope, limit: nil, offset: 0)
    rows = scope.except(:order, :includes, :preload, :eager_load)
      .select("#{location_id_sql} AS location_id, #{SELECT_SQL}")
      .group(Arel.sql(location_id_sql))
      .order(Arel.sql("photo_count DESC, newest_at DESC, location_id ASC"))
      .limit(limit).offset(offset).to_a
    places = PhotoPlace.where(id: rows.filter_map { |row| place_record_id(row.location_id) }).index_by(&:id)

    rows.map do |row|
      place = places[place_record_id(row.location_id)]
      PhotoLocationGroup.new(
        id: row.location_id, title: place&.name || title_for(row.latitude, row.longitude),
        photo_count: row.photo_count.to_i, image_count: row.image_count.to_i, video_count: row.video_count.to_i,
        latitude: row.latitude, longitude: row.longitude, place_type: place&.place_type,
        newest_at: row.newest_at, oldest_at: row.oldest_at,
        representative_photo_id: row.representative_photo_id, location_ids: [ row.location_id ]
      )
    end
  end

  def self.scope_for(scope, id)
    if place_record_id?(id)
      return scope.where(photo_metadata: { photo_place_id: place_record_id(id) })
    elsif legacy_place_id?(id)
      candidates = legacy_groups(scope, id)
      return candidates.one? ? scope_for(scope, candidates.first.id) : scope.none
    end

    if area_id?(id)
      scope = scope.where(photo_metadata: { photo_place_id: nil })
      id = id.delete_prefix(AREA_ID_PREFIX)
    end
    latitude_bucket, longitude_bucket = parse_id(id)
    return scope.none unless latitude_bucket && longitude_bucket

    scope.where(BUCKET_FILTER_SQL, bucket_bounds(latitude_bucket, longitude_bucket))
  end

  def self.scope_for_place_name(scope, name)
    scope_for(scope, place_id_for_name(name))
  end

  def self.legacy_groups(scope, id)
    name = place_name_from_id(id)
    return [] if name.blank?

    # Old links contained only a label. Preserve them as a choice of actual
    # places instead of silently unioning distant namesakes or old shared cells.
    legacy_cells = PhotoLocationPlace.where(name: name).pluck(:location_id)
    assigned = scope.where(photo_metadata: { photo_place_id: PhotoPlace.where(name: name).select(:id) })
    groups(assigned.or(scope_for_ids(scope, legacy_cells)))
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
    # Keep the indexed predicates on decimal columns while matching persisted
    # Float-derived IDs at exact boundaries (metadata coordinates have scale 6).
    {
      south: bucket_start(latitude_bucket), north: bucket_start(latitude_bucket + 1),
      west: bucket_start(longitude_bucket), east: bucket_start(longitude_bucket + 1)
    }
  end
  private_class_method :bucket_bounds

  def self.bucket_start(bucket)
    boundary = bucket * CELL_SIZE.to_d
    quotient = boundary.to_f / CELL_SIZE
    quotient.finite? && quotient.floor < bucket ? boundary + COORDINATE_STEP : boundary
  end
  private_class_method :bucket_start

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
    return true if place_record_id?(id)
    return place_name_from_id(id).present? if legacy_place_id?(id)

    parse_id(id.to_s.delete_prefix(AREA_ID_PREFIX)).all?
  end

  def self.area_id?(id)
    id.to_s.start_with?(AREA_ID_PREFIX)
  end

  def self.id_for_area(cell_id)
    "#{AREA_ID_PREFIX}#{cell_id}"
  end

  def self.id_for_metadata(metadata)
    return unless metadata&.latitude && metadata&.longitude
    return id_for_place(metadata.photo_place_id) if metadata.photo_place_id

    id_for_area(id_for_coordinates(metadata.latitude, metadata.longitude))
  end

  def self.place_id?(id)
    id.to_s.start_with?(PLACE_ID_PREFIX)
  end

  def self.place_record_id?(id)
    id.to_s.match?(/\Aplace-id-[1-9]\d*\z/)
  end

  def self.place_record_id(id)
    id.to_s.delete_prefix(RECORD_ID_PREFIX).to_i if place_record_id?(id)
  end

  def self.id_for_place(place)
    "#{RECORD_ID_PREFIX}#{place.respond_to?(:id) ? place.id : Integer(place)}"
  end

  def self.legacy_place_id?(id)
    place_id?(id) && !id.to_s.start_with?(RECORD_ID_PREFIX)
  end

  def self.place_id_for_name(name)
    "#{PLACE_ID_PREFIX}#{Base64.urlsafe_encode64(utf8_place_name(name), padding: false)}"
  end

  def self.place_name_from_id(id)
    return PhotoPlace.find_by(id: place_record_id(id))&.name if place_record_id?(id)
    return unless legacy_place_id?(id)

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
    latitude = coordinate_bucket_sql("COALESCE(photo_metadata.latitude, 0)")
    longitude = coordinate_bucket_sql("COALESCE(photo_metadata.longitude, 0)")
    "#{latitude}::bigint::text || '_' || #{longitude}::bigint::text"
  end

  def self.latitude_bucket_sql(cell_size: CELL_SIZE)
    coordinate_bucket_sql("photo_metadata.latitude", cell_size: cell_size)
  end

  def self.longitude_bucket_sql(cell_size: CELL_SIZE)
    coordinate_bucket_sql("photo_metadata.longitude", cell_size: cell_size)
  end

  def self.coordinate_bucket_sql(coordinate, cell_size: CELL_SIZE)
    # Use the same Float arithmetic as id_for_coordinates, including rounding.
    Photo.sanitize_sql_array([ "FLOOR(#{coordinate}::double precision / :cell_size::double precision)", { cell_size: cell_size } ])
  end
  private_class_method :coordinate_bucket_sql

  def self.format_coordinate(value)
    format("%.4f", value.to_f)
  end

  def self.utf8_place_name(value)
    value.to_s.dup.force_encoding(Encoding::UTF_8).scrub
  end
  private_class_method :utf8_place_name
end
