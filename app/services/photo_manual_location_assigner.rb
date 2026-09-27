class PhotoManualLocationAssigner
  def self.assign!(photo:, address:, result:)
    new(photo: photo, address: address, result: result).assign!
  end

  def self.restore!(metadata:)
    metadata.with_lock do
      return unless metadata.manual_location? && metadata.location? && metadata.photo_place_id.nil?

      manual = metadata.raw.fetch("manual_location", {})
      raw = metadata.raw.fetch("manual_location_geocode", {})
      name = manual["geocoded_name"].presence || manual["address"].presence
      return if name.blank?

      types = Array(raw["types"])
      provider_id = raw["place_id"].presence unless types.include?("plus_code")
      result = {
        name: name,
        names: [ name, manual["address"], *Array(raw["address_components"]).map { |component| component["long_name"] } ].compact_blank.uniq,
        identity_key: ("google:#{provider_id}" if provider_id),
        provider: ("google" if provider_id),
        provider_place_id: provider_id,
        place_type: provider_id ? types.first : "coordinate",
        raw: raw
      }.merge(LocationMapRegion.for_result(raw))
      place = PhotoPlace.from_geocode!(result: result, latitude: metadata.latitude, longitude: metadata.longitude)
      metadata.update!(photo_place: place, location_source: "manual")
      place
    end
  end

  def initialize(photo:, address:, result:)
    @photo = photo
    @address = address
    @result = result
  end

  def assign!
    metadata = nil
    PhotoMetadata.transaction do
      metadata = PhotoMetadata.for_photo(@photo)
      metadata.with_lock do
        now = Time.current
        raw = metadata.raw.to_h.deep_dup
        raw["manual_location"] = {
          "address" => @address,
          "geocoded_name" => @result.fetch(:name, nil),
          "geocoded_at" => now.iso8601,
          "source" => "owner"
        }
        raw["manual_location_geocode"] = @result.fetch(:raw, {}).to_h.except(:key_fingerprint, "key_fingerprint")

        metadata.assign_attributes(
          latitude: @result.fetch(:latitude),
          longitude: @result.fetch(:longitude),
          location_source: "manual",
          extraction_status: metadata.extraction_status.presence || "complete",
          extracted_at: metadata.extracted_at || now,
          raw: raw
        )
        metadata.photo_place = PhotoPlace.from_geocode!(result: @result, latitude: metadata.latitude, longitude: metadata.longitude)
        metadata.save!
      end
    end

    metadata
  end
end
