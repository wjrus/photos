# Resumable maintenance for existing names and unresolved coordinate assignments.
# Invoke after deployment; it never deploys, changes GPS, or rewrites manual edits.
class LocationEnrichmentRepair
  LOCK_KEY = 3_728_581_902
  STATUS_KEY = "native_location_repair_status_v1".freeze
  VERSION = LocationNativeGeocoder::VERSION

  def self.metadata_scope
    PhotoMetadata.geotagged.joins(:photo).merge(Photo.where(restricted: false, archived_at: nil))
      .where(location_source: [ nil, "automatic" ])
      .where("COALESCE(photo_metadata.raw->'manual_location'->>'source', '') != 'owner'")
  end

  def self.pending_places
    PhotoPlace.awaiting_native_names.where(id: metadata_scope.select(:photo_place_id))
  end

  def self.coordinate_photos
    metadata_scope.left_joins(:photo_place)
      .where("photo_metadata.photo_place_id IS NULL OR photo_places.place_type = 'coordinate' OR photo_places.identity_key LIKE 'coordinate:%'")
  end

  def self.pending_photos
    coordinate_photos.where("COALESCE(photo_metadata.raw->>'location_enrichment_version', '') != ?", VERSION)
  end

  def self.status
    setting = AppSetting.find_by(key: STATUS_KEY)
    { progress: setting ? JSON.parse(setting.value) : {}, budget: LocationApiBudget.status,
      named_places_remaining: pending_places.count, coordinate_photos_remaining: pending_photos.count,
      unresolved_coordinate_photos: coordinate_photos.count,
      unresolved_named_places: PhotoPlace.where(id: metadata_scope.select(:photo_place_id)).where("raw->>'native_checked_version' = ?", VERSION).count }
  end

  def self.run!(limit: 100, budget_cents: 5_000, area_query: nil, country_code: nil)
    limit = Integer(limit).clamp(1, 10_000)
    connection = ActiveRecord::Base.connection
    locked = ActiveRecord::Type::Boolean.new.cast(connection.select_value("SELECT pg_try_advisory_lock(#{LOCK_KEY})"))
    return { running: true } unless locked

    repair = new(limit: limit)
    LocationApiBudget.with_repair_limit(cents: budget_cents) { repair.run(area_query: area_query, country_code: country_code) }
    status
  rescue LocationApiBudget::Exceeded => error
    repair&.record("budget_exhausted", error: error.message)
    status
  rescue StandardError => error
    repair&.record("failed", error: error.class.name)
    raise
  ensure
    connection&.execute("SELECT pg_advisory_unlock(#{LOCK_KEY})") if locked
  end

  def initialize(limit:)
    @remaining = limit
    @counts = { "localized_places" => 0, "enriched_photos" => 0, "area_photos" => 0, "unresolved_places" => 0 }
  end

  def run(area_query:, country_code:)
    record("running")
    repair_area(area_query, country_code: country_code) if area_query.present?
    self.class.pending_places.order(:id).limit(@remaining).each do |place|
      localize_place(place)
      advance
    end
    self.class.pending_photos.order(:photo_id).limit(@remaining).each do |metadata|
      original_coordinates = [ metadata.latitude, metadata.longitude ]
      GeocodePhotoLocationJob.new.perform(metadata.photo_id, *original_coordinates, Time.current.to_f, refresh: true, landmarks: true)
      metadata.reload
      if metadata.raw["location_enrichment_version"] == VERSION
        @counts["enriched_photos"] += 1
      elsif !metadata.manual_location? && [ metadata.latitude, metadata.longitude ] == original_coordinates && self.class.pending_photos.exists?(id: metadata.id)
        raise LocationNativeGeocoder::LookupError, "Coordinate name enrichment did not complete"
      end
      advance
    end
    remaining = self.class.pending_places.exists? || self.class.pending_photos.exists?
    record(remaining ? "batch_complete" : "complete")
  end

  def record(state, error: nil)
    setting = AppSetting.find_or_initialize_by(key: STATUS_KEY)
    setting.update!(value: @counts.merge("state" => state, "updated_at" => Time.current.iso8601, "error" => error).compact.to_json)
  end

  private

  def localize_place(place)
    result = LocationReverseGeocoder.new.localize(place_id: place.provider_place_id, latitude: place.latitude, longitude: place.longitude)
    if result
      @counts["localized_places"] += 1 if place.refresh_native_name!(result)
    else
      unavailable_place(place)
    end
  rescue LocationNativeGeocoder::LookupError => error
    raise unless error.http_status == 404

    unavailable_place(place)
  end

  def unavailable_place(place)
    place.with_lock do
      return if place.manual_assignments.exists?

      place.update!(raw: place.raw.merge("native_checked_version" => VERSION))
      @counts["unresolved_places"] += 1
    end
  end

  def advance
    @remaining -= 1
    record("running") if (@counts.values.sum % 25).zero?
  end

  def repair_area(query, country_code:)
    result = LocationReverseGeocoder.new.named_area(query: query)
    unless result && %w[natural_feature national_park nature_preserve].include?(result[:place_type]) && result.dig(:raw, "geometry", "bounds").is_a?(Hash)
      raise LocationNativeGeocoder::LookupError, "Named area has no verifiable natural-feature bounds"
    end

    components = Array(result.dig(:raw, "address_components"))
    country = components.find { |component| Array(component["types"]).include?("country") }&.fetch("short_name", nil)
    raise LocationNativeGeocoder::LookupError, "Named area country did not match" if country_code.present? && country != country_code

    bounds = result.dig(:raw, "geometry", "bounds")
    south, west = Float(bounds.dig("southwest", "lat")), Float(bounds.dig("southwest", "lng"))
    north, east = Float(bounds.dig("northeast", "lat")), Float(bounds.dig("northeast", "lng"))
    distance = PhotoLocation.distance_meters(south, west, north, east)
    raise LocationNativeGeocoder::LookupError, "Named area bounds are invalid or too broad" unless distance && south <= north && distance <= 50_000

    photos = self.class.coordinate_photos.where("photo_metadata.latitude BETWEEN ? AND ?", south, north)
    photos = west <= east ? photos.where("photo_metadata.longitude BETWEEN ? AND ?", west, east) : photos.where("photo_metadata.longitude >= ? OR photo_metadata.longitude <= ?", west, east)
    center = result.fetch(:raw).dig("geometry", "location")
    place = PhotoPlace.from_geocode!(result: result, latitude: center.fetch("lat"), longitude: center.fetch("lng"))
    photos.order(:photo_id).limit(@remaining).each do |metadata|
      metadata.with_lock do
        next unless self.class.coordinate_photos.where(photo_id: metadata.photo_id).exists?
        next unless metadata.latitude.to_f.between?(south, north) && (west <= east ? metadata.longitude.to_f.between?(west, east) : metadata.longitude.to_f >= west || metadata.longitude.to_f <= east)

        metadata.update!(photo_place: place, location_source: "automatic", raw: metadata.raw.to_h.merge("location_enrichment_version" => VERSION))
        @counts["area_photos"] += 1
      end
      advance
    end
  end
end
