# Resolve presentation once and save it. Precise provider identity and photo GPS
# are deliberately separate from country headings and broad browsing galleries.
class LocationGroupingResolver
  VERSION = "grouping-v2".freeze

  def self.resolve(result, latitude:, longitude:, context: [], catalog: nil, force: false)
    return result unless force || result.dig(:raw, "native_name_version") == LocationNativeGeocoder::VERSION

    persist_catalog = catalog.nil?
    catalog ||= LocationGroupingCatalog.load
    catalog.observe(context)
    catalog.save! if persist_catalog
    raw = result.fetch(:raw).deep_dup
    country = catalog.country(raw)
    area = catalog.area(raw, latitude: latitude, longitude: longitude)
    country ||= catalog.data["countries"][area["country_code"]] if area
    raw["native_country"] = country if country
    raw["grouping_version"] = VERSION
    original_components = Array(raw["provider_address_components"] || raw["address_components"])
    components = original_components.map(&:deep_dup)
    if country
      component = components.find { |item| Array(item["types"]).include?("country") }
      if component
        component.merge!("long_name" => country["name"], "short_name" => country["code"], "language_code" => country["language_code"])
      else
        components << { "long_name" => country["name"], "short_name" => country["code"], "language_code" => country["language_code"], "types" => [ "country" ] }.compact
      end
    end

    city = catalog.city(raw, latitude: latitude, longitude: longitude)
    # Existing London membership is administrative, and intentionally spans its
    # boroughs. Other text/postal names require a real, geographically close city.
    legacy = LocationMapRegion.for_result(raw.except("grouping_version", "grouping"))
    region = if area
      { map_region_key: "owner-area:v1:#{Digest::SHA256.hexdigest(area['place_id'])}", map_region_name: area["name"] }
    elsif legacy[:map_region_key].to_s.start_with?('google-components:v1:["metro",')
      legacy
    elsif city
      source = raw.dig("native_locality", "source") == "reverse_geocoding" && raw.dig("native_locality", "place_id") == city["place_id"] ? "reverse_geocoding" : "catalog"
      raw["native_locality"] = { "place_id" => city["place_id"], "name" => city["name"], "source" => source }
      { map_region_key: "google-locality:v1:#{Digest::SHA256.hexdigest(city['place_id'])}", map_region_name: city["name"] }
    elsif result[:place_type] != "coordinate" && !result[:identity_key].to_s.start_with?("coordinate:")
      raw.delete("native_locality")
      { map_region_key: "google-feature:v1:#{Digest::SHA256.hexdigest(result.fetch(:identity_key))}", map_region_name: result.fetch(:name) }
    else
      raw.delete("native_locality")
      # Old deployed readers must not reactivate an unverified postal-town group.
      components.reject! { |item| (Array(item["types"]) & %w[locality postal_town]).any? }
      {}
    end
    raw["provider_address_components"] ||= original_components if original_components != components
    raw["address_components"] = components
    raw["grouping"] = region.stringify_keys
    result.merge(map_region_key: nil, map_region_name: nil).merge(region).merge(raw: raw, names: [ *Array(result[:names]), country&.fetch("name"), region[:map_region_name] ].compact_blank.uniq)
  end
end
