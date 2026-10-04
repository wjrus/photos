class MobileUploadChunk < ApplicationRecord
  belongs_to :mobile_upload
  has_one_attached :data

  validates :position, numericality: { only_integer: true, greater_than_or_equal_to: 0, less_than: 1024 }
end
