class PhotoLocationPlace < ApplicationRecord
  validates :location_id, :name, presence: true
  validates :location_id, uniqueness: true
end
