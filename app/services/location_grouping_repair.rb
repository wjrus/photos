# Rebuild presentation from saved provider responses. Optional missing-city
# queries are small, cached, and share the original repair spending allowance.
class LocationGroupingRepair
  LOCK_KEY = 3_728_581_903

  def self.places
    metadata = PhotoMetadata.geotagged.joins(:photo).merge(Photo.where(restricted: false, archived_at: nil))
    PhotoPlace.where(id: metadata.select(:photo_place_id))
  end

  def self.run!(apply: false, lookup: false, area_query: nil, area_name: nil, area_radius: 16_000)
    connection = ActiveRecord::Base.connection
    locked = ActiveRecord::Type::Boolean.new.cast(connection.select_value("SELECT pg_try_advisory_lock(#{LOCK_KEY})"))
    return { running: true } unless locked

    repair = new
    LocationApiBudget.with_repair_limit(cents: 5_000) do
      repair.configure_area(area_query, name: area_name, radius: area_radius) if area_query.present?
      repair.lookup_cities if lookup
      repair.run(apply: apply)
    end
  ensure
    connection&.execute("SELECT pg_advisory_unlock(#{LOCK_KEY})") if locked
  end

  def initialize
    @catalog = LocationGroupingCatalog.from_cached_responses
    @places = self.class.places.order(:id).to_a
  end

  def configure_area(query, name:, radius:)
    payload = LocationNativeGeocoder.new.address(address: query)
    result = Array(payload&.fetch("results", [])).find { |item| (Array(item["types"]) & %w[natural_feature national_park nature_preserve]).any? && !item["partial_match"] }
    raise LocationNativeGeocoder::LookupError, "Display area has no verified natural-feature result" unless result

    @catalog.observe([ result ])
    @catalog.add_area(result, name: name.presence || result.fetch("formatted_address").split(",", 2).first, radius: radius)
  end

  def lookup_cities
    @places.each do |place|
      raw = place.raw
      next if @catalog.city(raw, latitude: place.latitude, longitude: place.longitude) || @catalog.area(raw, latitude: place.latitude, longitude: place.longitude)

      query = @catalog.city_query(raw)
      next if query.blank? || @catalog.data["queries"].include?(query)

      payload = LocationNativeGeocoder.new.address(address: query)
      @catalog.observe(Array(payload&.fetch("results", [])))
      @catalog.record_query(query)
    end
  end

  def run(apply:)
    changed, unchanged, skipped = 0, 0, 0
    @catalog.save! if apply
    changes = []
    @places.each do |place|
      result = LocationGroupingResolver.resolve({ identity_key: place.identity_key, name: place.name, names: place.names, place_type: place.place_type, raw: place.raw, map_region_key: place.map_region_key, map_region_name: place.map_region_name },
        latitude: place.latitude, longitude: place.longitude, catalog: @catalog, force: true)
      if place.raw == result[:raw] && place.map_region_key == result[:map_region_key] && place.map_region_name == result[:map_region_name]
        unchanged += 1
        next
      end

      changes << { from: place.map_region_name, to: result[:map_region_name] }
      if !apply || place.apply_grouping!(result, expected_raw: place.raw.deep_dup)
        changed += 1
      else
        skipped += 1
      end
    end
    { applied: apply, changed: changed, unchanged: unchanged, concurrent_changes_skipped: skipped,
      countries: @catalog.data["countries"].values.map { |country| country.slice("code", "name") },
      cities: @catalog.data["cities"].size, areas: @catalog.data["areas"].map { |area| area.slice("name", "radius") },
      renamed_groups: changes.uniq, budget: LocationApiBudget.status }
  end
end
