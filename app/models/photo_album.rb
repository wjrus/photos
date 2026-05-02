class PhotoAlbum < ApplicationRecord
  SOURCES = %w[manual google_takeout].freeze

  belongs_to :owner, class_name: "User", inverse_of: :photo_albums
  has_many :photo_album_memberships, dependent: :destroy
  has_many :photos, through: :photo_album_memberships

  validates :title, presence: true
  validates :source, inclusion: { in: SOURCES }
end
