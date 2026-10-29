require "digest"

# Small, rebuildable browsing catalog. Provider responses stay in their own
# permanent cache; this database setting records canonical countries/cities and
# explicitly requested display areas, independently of precise photo places.
class LocationGroupingCatalog
  SETTING_KEY = "location_grouping_catalog/v1".freeze
  MAX_CITY_DISTANCE = 32_000

  attr_reader :data

  def initialize(data = {})
    @data = { "countries" => {}, "cities" => {}, "areas" => [], "queries" => [] }.merge(data)
    @changed = false
  end

  def self.load
    value = AppSetting.find_by(key: SETTING_KEY)&.value
    new(value.present? ? JSON.parse(value) : {})
  end

  def self.from_cached_responses
    saved = load.data
    catalog = new("areas" => saved["areas"], "queries" => saved["queries"])
    votes = Hash.new { |hash, key| hash[key] = Hash.new(0) }
    LocationGeocodingResponse.where("request_key LIKE ?", "google-geocoding-v4/#{LocationNativeGeocoder::VERSION}/%").find_each(batch_size: 100) do |cached|
      payload = cached.payload
      Array(payload["results"] || (payload["placeId"] ? [ payload ] : [])).each do |result|
        country = component(result, "country")
        if country && (code = short_name(country)).present? && long_name(country).present?
          votes[code][[ long_name(country), country["languageCode"] ]] += 1
        end
        catalog.observe([ result ])
      end
    end
    votes.each do |code, names|
      (name, language), = names.max_by { |(name, _language), count| [ count, name.to_s ] }
      catalog.data["countries"][code] = { "code" => code, "name" => name, "language_code" => language }.compact
    end
    catalog
  end

  def observe(results)
    Array(results).each do |result|
      country = self.class.component(result, "country")
      code = self.class.short_name(country)
      next if code.blank? || self.class.long_name(country).blank?

      unless data["countries"].key?(code)
        data["countries"][code] = { "code" => code, "name" => self.class.long_name(country), "language_code" => country["language_code"] || country["languageCode"] }.compact
        @changed = true
      end
      type = %w[locality postal_town].find { |item| Array(result["types"]).include?(item) }
      id = result["place_id"] || result["placeId"]
      name = self.class.long_name(self.class.component(result, type)) if type
      point = result.dig("geometry", "location") || result["location"]
      next if id.blank? || name.blank? || !valid_point?(point)

      state = self.class.component(result, "administrative_area_level_1")
      city = { "place_id" => id, "name" => name, "country_code" => code, "type" => type,
        "state_code" => self.class.short_name(state), "state_name" => self.class.long_name(state),
        "latitude" => point.fetch("lat", point["latitude"]).to_f, "longitude" => point.fetch("lng", point["longitude"]).to_f }
      if !data["cities"].key?(id) || data["cities"][id]["type"].blank?
        data["cities"][id] = city
        @changed = true
      end
    end
  end

  def country(raw)
    code = self.class.short_name(self.class.component(raw, "country")) || raw.dig("native_country", "code")
    return data["countries"][code] if code.present?

    name = normalize(self.class.long_name(self.class.component(raw, "country")))
    matches = data["countries"].values.select { |country| normalize(country["name"]) == name } if name.present?
    matches.sole if matches&.one?
  end

  def city(raw, latitude:, longitude:)
    code = country(raw)&.fetch("code")
    verified = raw.dig("native_locality", "source") == "reverse_geocoding" || raw["grouping_version"].blank?
    direct = data["cities"][raw.dig("native_locality", "place_id")] if verified
    return direct if direct && direct["country_code"] == code && direct["type"] != "postal_town"

    names = hints(raw)
    state = self.class.component(raw, "administrative_area_level_1")
    names.each do |name|
      candidates = data["cities"].values.select do |candidate|
        candidate["country_code"] == code && name == normalize(candidate["name"]) && state_matches?(state, candidate) &&
          PhotoLocation.distance_meters(latitude, longitude, candidate["latitude"], candidate["longitude"])&.<=(MAX_CITY_DISTANCE)
      end
      localities = candidates.select { |candidate| candidate["type"] == "locality" }
      candidates = localities if localities.any?
      return candidates.one? ? candidates.sole : nil if candidates.any?
    end
    nil
  end

  def hints(raw)
    name = %w[locality postal_town].filter_map { |type| self.class.long_name(self.class.component(raw, type)).presence }.first
    name ? [ normalize(name) ] : []
  end

  def city_query(raw)
    name = %w[locality postal_town].filter_map { |type| self.class.long_name(self.class.component(raw, type)) }.first
    code = country(raw)&.fetch("code")
    return if name.blank? || code.blank?

    state = self.class.component(raw, "administrative_area_level_1")
    county = self.class.component(raw, "administrative_area_level_2")
    [ name, self.class.long_name(county), self.class.short_name(state) || self.class.long_name(state), code ].compact_blank.uniq.join(", ")
  end

  def add_area(result, name:, radius:)
    raise ArgumentError, "Display area radius must be at most 20 km" unless radius.positive? && radius <= 20_000

    point = result.dig("geometry", "location")
    raise ArgumentError, "Display area must have a provider identity and point" unless result["place_id"].present? && valid_point?(point)

    area = { "place_id" => result["place_id"], "name" => name, "country_code" => self.class.short_name(self.class.component(result, "country")),
      "latitude" => point["lat"].to_f, "longitude" => point["lng"].to_f, "radius" => radius }
    data["areas"] = data["areas"].reject { |existing| existing["place_id"] == area["place_id"] } + [ area ]
    @changed = true
  end

  def area(raw, latitude:, longitude:)
    code = country(raw)&.fetch("code")
    candidates = data["areas"].select do |area|
      (code.blank? || area["country_code"] == code) && PhotoLocation.distance_meters(latitude, longitude, area["latitude"], area["longitude"])&.<=(area["radius"])
    end
    candidates.sole if candidates.one?
  end

  def save!
    return unless @changed

    now = Time.current
    AppSetting.insert_all([ { key: SETTING_KEY, value: "{}", created_at: now, updated_at: now } ], unique_by: :key)
    setting = AppSetting.find_by!(key: SETTING_KEY)
    setting.with_lock do
      current = self.class.new(JSON.parse(setting.value)).data
      merged = { "countries" => current["countries"].merge(data["countries"]), "cities" => current["cities"].merge(data["cities"]),
        "areas" => (current["areas"] + data["areas"]).index_by { |area| area["place_id"] }.values,
        "queries" => (current["queries"] + data["queries"]).uniq }
      setting.update!(value: merged.to_json)
      @data = merged
    end
    @changed = false
  end

  def record_query(query)
    data["queries"] |= [ query ]
    @changed = true
  end

  def self.component(result, type)
    Array(result["provider_address_components"] || result["address_components"] || result["addressComponents"]).find { |item| Array(item["types"]).include?(type) }
  end

  def self.long_name(component)
    component && (component["long_name"] || component["longText"])
  end

  def self.short_name(component)
    component && (component["short_name"] || component["shortText"])
  end

  private

  def normalize(value)
    value.to_s.unicode_normalize(:nfc).squish.downcase
  end

  def state_matches?(state, candidate)
    code, name = self.class.short_name(state), self.class.long_name(state)
    return true if code.blank? && name.blank?
    return true if candidate["state_code"].blank? && candidate["state_name"].blank?

    [ code, name ].compact.any? { |value| [ candidate["state_code"], candidate["state_name"] ].compact.any? { |other| normalize(value) == normalize(other) } }
  end

  def valid_point?(point)
    return false unless point.is_a?(Hash)

    latitude = Float(point.fetch("lat", point["latitude"]))
    longitude = Float(point.fetch("lng", point["longitude"]))
    latitude.finite? && longitude.finite? && (-90..90).cover?(latitude) && (-180..180).cover?(longitude)
  rescue ArgumentError, TypeError
    false
  end
end
