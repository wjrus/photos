class PhotoMetadata < ApplicationRecord
  self.table_name = "photo_metadata"

  EXTRACTION_STATUSES = %w[pending complete unsupported failed].freeze

  belongs_to :photo
  belongs_to :photo_place, optional: true, inverse_of: :photo_metadata

  scope :geotagged, -> { where.not(latitude: nil).where.not(longitude: nil) }

  validates :extraction_status, inclusion: { in: EXTRACTION_STATUSES }
  validates :location_source, inclusion: { in: %w[automatic manual] }, allow_nil: true

  before_validation :clear_stale_automatic_place
  after_commit :enqueue_location_geocoding, on: %i[create update], if: :location_coordinates_changed?
  after_commit :invalidate_location_bounds, if: -> { destroyed? || location_assignment_changed? }

  def self.for_photo(photo)
    photo.metadata || find_or_create_by!(photo_id: photo.id)
  end

  def location?
    latitude.present? && longitude.present?
  end

  def video?
    video_codec.present? || audio_codec.present? || video_container.present? || video_duration.present?
  end

  def manual_location?
    manual = raw.to_h["manual_location"]
    location_source == "manual" || (manual.is_a?(Hash) && manual["source"] == "owner")
  end

  def update_extracted!(attributes)
    with_lock do
      attributes = attributes.symbolize_keys
      if manual_location?
        attributes.except!(:latitude, :longitude, :photo_place_id, :location_source)
        if attributes.key?(:raw)
          attributes[:raw] = attributes[:raw].to_h.merge(raw.to_h.slice("manual_location", "manual_location_geocode"))
        end
        attributes[:location_source] = "manual"
      end
      update!(attributes)
    end
  end

  private

  def clear_stale_automatic_place
    return if new_record? || manual_location? || !(will_save_change_to_latitude? || will_save_change_to_longitude?)

    self.photo_place = nil
    self.location_source = nil
  end

  def location_coordinates_changed?
    previous_changes.key?("latitude") || previous_changes.key?("longitude")
  end

  def location_assignment_changed?
    location_coordinates_changed? || previous_changes.key?("photo_place_id")
  end

  def invalidate_location_bounds
    place_ids = [ photo_place_id, *previous_changes.fetch("photo_place_id", []) ].compact.uniq
    ids = place_ids.map { |id| PhotoLocation.id_for_place(id) }
    coordinates = [
      [ latitude, longitude ],
      [ previous_changes.fetch("latitude", [ latitude ]).first, previous_changes.fetch("longitude", [ longitude ]).first ]
    ]
    coordinates.each do |lat, lng|
      next unless lat && lng

      cell_id = PhotoLocation.id_for_coordinates(lat, lng)
      ids << cell_id << PhotoLocation.id_for_area(cell_id)
    end
    PhotoLocationBound.where(location_id: ids.uniq).delete_all if ids.any?
  end

  def enqueue_location_geocoding
    return unless location?
    return if manual_location? || photo_place_id.present? || photo.restricted? || photo.archived?
    return unless LocationReverseGeocoder.api_key.present?

    GeocodePhotoLocationJob.perform_later(photo_id, latitude, longitude)
  end
end
