class PhotoLocationBound < ApplicationRecord
  validates :location_id, presence: true, uniqueness: true
  validates :south, :north, :west, :east, :photo_count, :calculated_at, presence: true

  def self.refresh_all!
    now = Time.current
    active_ids = []

    refresh_bucket_bounds!(calculated_at: now).each { |location_id| active_ids << location_id }
    refresh_place_bounds!(calculated_at: now).each { |location_id| active_ids << location_id }

    active_ids.any? ? where.not(location_id: active_ids).delete_all : delete_all
    active_ids.size
  end

  def padded_bounds
    south_value = south.to_f
    north_value = north.to_f
    west_value = west.to_f
    east_value = east.to_f
    latitude_padding = [ (north_value - south_value).abs * 0.5, 0.04 ].max
    longitude_padding = [ (east_value - west_value).abs * 0.5, 0.04 ].max

    {
      south: (south_value - latitude_padding).clamp(-90.0, 90.0),
      north: (north_value + latitude_padding).clamp(-90.0, 90.0),
      west: (west_value - longitude_padding).clamp(-180.0, 180.0),
      east: (east_value + longitude_padding).clamp(-180.0, 180.0)
    }
  end

  def self.refresh_bucket_bounds!(calculated_at:)
    bounds = visible_geotagged_photos
      .select(bucket_bounds_select_sql)
      .group(Arel.sql(PhotoLocation.latitude_bucket_sql), Arel.sql(PhotoLocation.longitude_bucket_sql))

    upsert_bounds(bounds.map { |row| bounds_attributes(row, calculated_at: calculated_at) })
  end
  private_class_method :refresh_bucket_bounds!

  def self.refresh_place_bounds!(calculated_at:)
    PhotoLocationPlace
      .where.not(name: [ nil, "" ])
      .distinct
      .pluck(:name)
      .filter_map do |place_name|
        scope = PhotoLocation.scope_for_place_name(visible_geotagged_photos, place_name)
        row = scope.reselect(bounds_select_sql).take
        next unless row&.south && row&.north && row&.west && row&.east

        {
          location_id: PhotoLocation.place_id_for_name(place_name),
          south: row.south,
          north: row.north,
          west: row.west,
          east: row.east,
          photo_count: row.photo_count.to_i,
          calculated_at: calculated_at,
          created_at: calculated_at,
          updated_at: calculated_at
        }
      end.then { |attributes| upsert_bounds(attributes) }
  end
  private_class_method :refresh_place_bounds!

  def self.upsert_bounds(attributes)
    return [] if attributes.empty?

    upsert_all(attributes, unique_by: :index_photo_location_bounds_on_location_id)
    attributes.map { |row| row.fetch(:location_id) }
  end
  private_class_method :upsert_bounds

  def self.visible_geotagged_photos
    Photo
      .where(restricted: false, archived_at: nil)
      .joins(:metadata)
      .where.not(photo_metadata: { latitude: nil, longitude: nil })
  end
  private_class_method :visible_geotagged_photos

  def self.bucket_bounds_select_sql
    Photo.sanitize_sql_array([
      <<~SQL.squish,
        FLOOR(photo_metadata.latitude / :cell_size) AS latitude_bucket,
        FLOOR(photo_metadata.longitude / :cell_size) AS longitude_bucket,
        #{bounds_select_sql}
      SQL
      { cell_size: PhotoLocation::CELL_SIZE }
    ])
  end
  private_class_method :bucket_bounds_select_sql

  def self.bounds_select_sql
    <<~SQL.squish
      MIN(photo_metadata.latitude) AS south,
      MAX(photo_metadata.latitude) AS north,
      MIN(photo_metadata.longitude) AS west,
      MAX(photo_metadata.longitude) AS east,
      COUNT(*) AS photo_count
    SQL
  end
  private_class_method :bounds_select_sql

  def self.bounds_attributes(row, calculated_at:)
    {
      location_id: PhotoLocation.id_for(row.latitude_bucket, row.longitude_bucket),
      south: row.south,
      north: row.north,
      west: row.west,
      east: row.east,
      photo_count: row.photo_count.to_i,
      calculated_at: calculated_at,
      created_at: calculated_at,
      updated_at: calculated_at
    }
  end
  private_class_method :bounds_attributes
end
