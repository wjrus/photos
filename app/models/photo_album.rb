class PhotoAlbum < ApplicationRecord
  SOURCES = %w[manual google_takeout].freeze
  VISIBILITIES = %w[private public].freeze

  belongs_to :owner, class_name: "User", inverse_of: :photo_albums
  has_many :photo_album_memberships, dependent: :destroy
  has_many :photos, through: :photo_album_memberships

  validates :title, presence: true
  validates :source, inclusion: { in: SOURCES }
  validates :visibility, inclusion: { in: VISIBILITIES }

  scope :visible_to, ->(user) {
    if user&.owner?
      all
    else
      where(visibility: "public")
    end
  }
  scope :display_order, -> { order(Arel.sql("LOWER(photo_albums.title) ASC")) }

  def public?
    visibility == "public"
  end

  def private?
    visibility == "private"
  end

  def publish!
    update!(visibility: "public", published_at: Time.current)
  end

  def unpublish!
    update!(visibility: "private", published_at: nil)
  end
end
