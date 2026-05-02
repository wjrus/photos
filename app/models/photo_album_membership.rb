class PhotoAlbumMembership < ApplicationRecord
  belongs_to :photo
  belongs_to :photo_album

  validates :photo_id, uniqueness: { scope: :photo_album_id }
end
