class PhotoLocationCover < ApplicationRecord
  belongs_to :owner, class_name: "User", inverse_of: :photo_location_covers
  belongs_to :cover_photo, class_name: "Photo"

  validates :location_id, presence: true
  validates :location_id, uniqueness: { scope: :owner_id }
end
