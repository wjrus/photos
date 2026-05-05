class PhotoLocationPlace < ApplicationRecord
  validates :location_id, :name, presence: true
  validates :location_id, uniqueness: true

  before_validation :ensure_primary_name_tag

  def self.matching_name(query)
    where(
      "photo_location_places.name ILIKE :query OR EXISTS (
        SELECT 1
        FROM jsonb_array_elements_text(photo_location_places.names) AS location_name(value)
        WHERE location_name.value ILIKE :query
      )",
      query: query
    )
  end

  private

  def ensure_primary_name_tag
    self.names = Array(names).compact_blank
    self.names = [ name, *names ].compact_blank.uniq
  end
end
