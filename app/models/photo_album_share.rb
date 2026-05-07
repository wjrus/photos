class PhotoAlbumShare < ApplicationRecord
  belongs_to :photo_album
  belongs_to :user
  belongs_to :shared_by, class_name: "User"

  validates :user_id, uniqueness: { scope: :photo_album_id }
  validate :user_must_be_invited_viewer

  private

  def user_must_be_invited_viewer
    return if user&.viewer? && user.invited?

    errors.add(:user, "must be an invited viewer")
  end
end
