class PhotoPeopleTag < ApplicationRecord
  belongs_to :photo
  belongs_to :user
  belongs_to :tagged_by, class_name: "User"

  validates :user_id, uniqueness: { scope: :photo_id }
end
