class PhotoManualLocationAssigner
  def self.assign!(photo:, address:, result:)
    new(photo: photo, address: address, result: result).assign!
  end

  def initialize(photo:, address:, result:)
    @photo = photo
    @address = address
    @result = result
  end

  def assign!
    now = Time.current
    metadata = PhotoMetadata.for_photo(@photo)
    raw = metadata.raw.to_h.deep_dup
    raw["manual_location"] = {
      "address" => @address,
      "geocoded_name" => @result.fetch(:name, nil),
      "geocoded_at" => now.iso8601,
      "source" => "owner"
    }
    raw["manual_location_geocode"] = @result.fetch(:raw, {})

    metadata.update!(
      latitude: @result.fetch(:latitude),
      longitude: @result.fetch(:longitude),
      extraction_status: metadata.extraction_status.presence || "complete",
      extracted_at: metadata.extracted_at || now,
      raw: raw
    )

    PhotoLocationPlace.upsert(
      {
        location_id: PhotoLocation.id_for_coordinates(@result.fetch(:latitude), @result.fetch(:longitude)),
        name: @result.fetch(:name),
        names: @result.fetch(:names, [ @result.fetch(:name) ]),
        latitude: @result.fetch(:latitude),
        longitude: @result.fetch(:longitude),
        raw: @result.fetch(:raw, {}).except(:key_fingerprint),
        geocoded_at: now,
        created_at: now,
        updated_at: now
      },
      unique_by: :index_photo_location_places_on_location_id
    )

    metadata
  end
end
