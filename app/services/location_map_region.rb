class LocationMapRegion
  KEY_PREFIX = "google-components:v1:".freeze

  def self.for_result(result)
    new(result).descriptor
  end

  def initialize(result)
    @components = result.to_h.with_indifferent_access.fetch(:address_components, [])
  end

  def descriptor
    country = country_key
    admin1 = component_name("administrative_area_level_1")
    admin2 = component_name("administrative_area_level_2")
    return {} if [ country, admin1, admin2 ].any?(&:blank?)

    # This is a map presentation hierarchy, never a place identity. Google's
    # actual component containment is required; a borough name or nearby point
    # alone cannot imply Greater London membership.
    if country == "gb" && normalize(admin2) == "greater london"
      return descriptor_for("metro", [ country, admin1, admin2 ], "London")
    end

    locality = component_name("locality") || component_name("postal_town")
    return {} if locality.blank?

    descriptor_for("locality", [ country, admin1, admin2, locality ], locality)
  end

  private

  def descriptor_for(kind, hierarchy, name)
    {
      map_region_key: "#{KEY_PREFIX}#{[ kind, *hierarchy.map { |part| normalize(part) } ].to_json}",
      map_region_name: name
    }
  end

  def country_key
    country = component("country")
    return unless country

    name = normalize(country[:long_name])
    return "gb" if normalize(country[:short_name]) == "gb" || name == "united kingdom"

    # Always use the same field for other countries. Switching between an
    # optional short code and its full name would split otherwise equal regions.
    name.presence
  end

  def component_name(type)
    component(type)&.fetch(:long_name, nil)&.squish.presence
  end

  def component(type)
    @components.find { |candidate| Array(candidate[:types]).include?(type) }
  end

  def normalize(value)
    value.to_s.unicode_normalize(:nfc).squish.downcase
  end
end
