class PhotoPlace < ApplicationRecord
  has_many :photo_metadata, class_name: "PhotoMetadata", inverse_of: :photo_place, dependent: :restrict_with_exception

  validates :identity_key, :name, presence: true

  before_validation :ensure_primary_name_tag

  def self.from_geocode!(result:, latitude:, longitude:)
    identity = result[:identity_key].presence || coordinate_identity(latitude, longitude)
    # Coordinate identities follow the stored precision even when an address
    # provider returns extra digits or a signed zero.
    identity = coordinate_identity(latitude, longitude) if identity.start_with?("coordinate:")
    place = create_or_find_by!(identity_key: identity) do |place|
      place.assign_attributes(
        name: result.fetch(:name),
        names: result.fetch(:names, []),
        provider: result[:provider],
        provider_place_id: result[:provider_place_id],
        place_type: result[:place_type] || ("coordinate" if identity.start_with?("coordinate:")),
        map_region_key: result[:map_region_key],
        map_region_name: result[:map_region_name],
        latitude: latitude,
        longitude: longitude,
        raw: result.fetch(:raw, {}).to_h.except(:key_fingerprint, "key_fingerprint"),
        geocoded_at: Time.current
      )
    end

    place.with_lock do
      # A later match can supply hierarchy that was missing from the first
      # response. Keep an established region and require a complete descriptor.
      if (place.map_region_key.blank? || place.map_region_name.blank?) && result[:map_region_key].present? && result[:map_region_name].present?
        place.assign_attributes(map_region_key: result[:map_region_key], map_region_name: result[:map_region_name])
      end
      place.names = [ *place.names, result[:name], *Array(result[:names]), place.map_region_name ].compact_blank.uniq
      place.save! if place.changed?
    end
    place
  end

  def self.coordinate_identity(latitude, longitude)
    coordinates = [ latitude, longitude ].map do |value|
      rounded = BigDecimal(value.to_s).round(6)
      format("%.6f", rounded.zero? ? 0 : rounded)
    end
    "coordinate:#{coordinates.join(',')}"
  end
  private_class_method :coordinate_identity

  def self.matching_name(query)
    where(
      "photo_places.name ILIKE :query OR EXISTS (
        SELECT 1 FROM jsonb_array_elements_text(photo_places.names) AS place_name(value)
        WHERE place_name.value ILIKE :query
      )",
      query: query
    )
  end

  private

  def ensure_primary_name_tag
    self.names = [ name, *Array(names), map_region_name ].compact_blank.uniq
  end
end
