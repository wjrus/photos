require "digest"

# Browsing areas summarize precise places without changing any photo assignment.
class PhotoLocationArea
  CELL_SIZE = 0.125 # About 8.6 miles north/south; a bounded fallback, not a radius.
  PLUS_CODE_PREFIX = '^[23456789CFGHJMPQRVWX]{4,8}\+[23456789CFGHJMPQRVWX]{2,3}([[:space:]]+|$)'.freeze
  COMPONENTS_JOIN = <<~SQL.squish.freeze
    LEFT JOIN photo_places location_area_places ON location_area_places.id = photo_metadata.photo_place_id
    LEFT JOIN LATERAL (
      SELECT
        MAX(component->>'long_name') FILTER (WHERE component->'types' ? 'locality') AS locality,
        MAX(component->>'long_name') FILTER (WHERE component->'types' ? 'postal_town') AS postal_town,
        MAX(component->>'long_name') FILTER (WHERE component->'types' ? 'country') AS country,
        MAX(component->>'long_name') FILTER (WHERE component->'types' ? 'administrative_area_level_1') AS region,
        MAX(component->>'long_name') FILTER (WHERE component->'types' ? 'administrative_area_level_2') AS county
      FROM jsonb_array_elements(CASE
        WHEN jsonb_typeof(location_area_places.raw->'address_components') = 'array'
        THEN location_area_places.raw->'address_components' ELSE '[]'::jsonb END) AS component
    ) location_area_components ON TRUE
  SQL
  LOCALITY_SQL = "COALESCE(NULLIF(location_area_components.locality, ''), NULLIF(location_area_components.postal_town, ''))".freeze
  COUNTRY_SQL = "CASE WHEN LOWER(location_area_components.country) = 'united kingdom' THEN 'gb' ELSE LOWER(location_area_components.country) END".freeze
  LONDON_SQL = "(#{COUNTRY_SQL}) = 'gb' AND LOWER(location_area_components.county) = 'greater london' AND NULLIF(location_area_components.region, '') IS NOT NULL".freeze
  CITY_KEY_SQL = <<~SQL.squish.freeze
    'google-components:v1:[' || array_to_string(ARRAY[
      to_jsonb('locality'::text)::text, to_jsonb((#{COUNTRY_SQL}))::text,
      to_jsonb(LOWER(location_area_components.region))::text,
      to_jsonb(LOWER(location_area_components.county))::text, to_jsonb(LOWER(#{LOCALITY_SQL}))::text
    ], ',') || ']'
  SQL
  REGION_KEY_SQL = <<~SQL.squish.freeze
    CASE
      WHEN NULLIF(location_area_places.map_region_key, '') IS NOT NULL
        AND NULLIF(location_area_places.map_region_name, '') IS NOT NULL
      THEN location_area_places.map_region_key
      WHEN #{LONDON_SQL}
      THEN 'google-components:v1:[' || array_to_string(ARRAY[
        to_jsonb('metro'::text)::text, to_jsonb('gb'::text)::text,
        to_jsonb(LOWER(location_area_components.region))::text, to_jsonb('greater london'::text)::text
      ], ',') || ']'
      WHEN #{LOCALITY_SQL} IS NOT NULL AND NULLIF(location_area_components.country, '') IS NOT NULL
        AND NULLIF(location_area_components.region, '') IS NOT NULL AND NULLIF(location_area_components.county, '') IS NOT NULL
      THEN #{CITY_KEY_SQL}
      WHEN #{LOCALITY_SQL} IS NOT NULL AND NULLIF(location_area_components.country, '') IS NOT NULL
        AND NULLIF(location_area_components.region, '') IS NOT NULL
      THEN 'saved-components:v1:' || jsonb_build_array(
        LOWER(location_area_components.country), LOWER(location_area_components.region),
        COALESCE(LOWER(location_area_components.county),
          FLOOR(photo_metadata.latitude)::text || '_' || FLOOR(photo_metadata.longitude)::text),
        LOWER(#{LOCALITY_SQL}))::text
    END
  SQL
  REGION_NAME_SQL = <<~SQL.squish.freeze
    CASE WHEN NULLIF(location_area_places.map_region_key, '') IS NOT NULL
      AND NULLIF(location_area_places.map_region_name, '') IS NOT NULL
      THEN location_area_places.map_region_name WHEN #{LONDON_SQL} THEN 'London' ELSE #{LOCALITY_SQL} END
  SQL
  UNCERTAIN_SQL = <<~SQL.squish.freeze
    (location_area_places.id IS NULL OR location_area_places.place_type = 'coordinate'
      OR location_area_places.identity_key LIKE 'coordinate:%')
  SQL
  ID_SQL = <<~SQL.squish.freeze
    CASE WHEN (#{REGION_KEY_SQL}) IS NOT NULL
      THEN 'region-' || encode(sha256(convert_to((#{REGION_KEY_SQL}), 'UTF8')), 'hex')
      WHEN #{UNCERTAIN_SQL}
      THEN 'nearby-' || FLOOR(photo_metadata.latitude / #{CELL_SIZE})::bigint::text
        || '_' || FLOOR(photo_metadata.longitude / #{CELL_SIZE})::bigint::text
      ELSE 'place-id-' || location_area_places.id::text END
  SQL
  HINT_SQL = <<~SQL.squish.freeze
    COALESCE(#{LOCALITY_SQL}, CASE WHEN location_area_places.name ~* '#{PLUS_CODE_PREFIX}'
      THEN NULLIF(BTRIM(regexp_replace(location_area_places.name, '#{PLUS_CODE_PREFIX}', '', 'i')), '') END)
  SQL
  TITLE_SQL = <<~SQL.squish.freeze
    CASE WHEN MAX((#{REGION_KEY_SQL})) IS NOT NULL
      THEN MAX((#{REGION_NAME_SQL}))
      WHEN BOOL_OR(#{UNCERTAIN_SQL})
      THEN CASE WHEN COUNT(DISTINCT (#{HINT_SQL})) = 1 THEN MAX((#{HINT_SQL})) END
      ELSE MAX(location_area_places.name) END
  SQL

  def self.grouped_id?(id)
    id.to_s.match?(/\Aregion-[a-f0-9]{64}\z/) || nearby_buckets(id).present?
  end

  def self.id_for_region(key)
    "region-#{Digest::SHA256.hexdigest(key)}"
  end

  def self.id_for_coordinates(latitude, longitude)
    "nearby-#{(latitude.to_f / CELL_SIZE).floor}_#{(longitude.to_f / CELL_SIZE).floor}"
  end

  def self.group_count(scope)
    joined(scope.except(:order, :includes, :preload, :eager_load)).distinct.count(Arel.sql(ID_SQL))
  end

  def self.groups(scope, limit: nil, offset: 0, sort: "count")
    rows = joined(scope.except(:order, :includes, :preload, :eager_load))
      .select("#{ID_SQL} AS location_id, #{TITLE_SQL} AS area_name, MIN(location_area_places.place_type) AS place_type, #{PhotoLocation::SELECT_SQL}")
      .group(Arel.sql(ID_SQL))
    ordering = sort == "name" ? "LOWER(#{TITLE_SQL}) ASC NULLS LAST, latitude ASC, longitude ASC, location_id ASC" : "photo_count DESC, newest_at DESC, location_id ASC"
    rows.order(Arel.sql(ordering)).limit(limit).offset(offset).map do |row|
      nearby = row.location_id.start_with?("nearby-")
      PhotoLocationGroup.new(
        id: row.location_id, title: row.area_name.presence || "Nearby #{PhotoLocation.title_for(row.latitude, row.longitude)}",
        photo_count: row.photo_count.to_i, image_count: row.image_count.to_i, video_count: row.video_count.to_i,
        latitude: row.latitude, longitude: row.longitude,
        place_type: nearby ? "nearby_area" : row.location_id.start_with?("region-") ? "town_or_area" : row.place_type,
        newest_at: row.newest_at, oldest_at: row.oldest_at, representative_photo_id: row.representative_photo_id,
        location_ids: [ row.location_id ]
      )
    end
  end

  def self.scope_for(scope, id)
    return scope.none unless grouped_id?(id)

    if (buckets = nearby_buckets(id))
      south, west = buckets.map { |bucket| bucket * CELL_SIZE.to_d }
      scope = scope.where("photo_metadata.latitude >= ? AND photo_metadata.latitude < ? AND photo_metadata.longitude >= ? AND photo_metadata.longitude < ?",
        south, south + CELL_SIZE.to_d, west, west + CELL_SIZE.to_d)
    end
    joined(scope).where("(#{ID_SQL}) = ?", id)
  end

  def self.identities(scope)
    joined(scope.except(:order, :includes, :preload, :eager_load)).pluck("photos.id", Arel.sql(ID_SQL)).to_h
  end

  def self.joined(scope)
    scope.joins(COMPONENTS_JOIN)
  end
  private_class_method :joined

  def self.nearby_buckets(id)
    match = /\Anearby-(-?\d{1,4})_(-?\d{1,4})\z/.match(id.to_s)
    return unless match

    latitude, longitude = match.captures.map(&:to_i)
    [ latitude, longitude ] if (-720..720).cover?(latitude) && (-1440..1440).cover?(longitude)
  end
  private_class_method :nearby_buckets
end
