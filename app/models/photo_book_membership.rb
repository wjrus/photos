class PhotoBookMembership < ApplicationRecord
  belongs_to :photo_book
  belongs_to :photo

  validates :photo_id, uniqueness: { scope: :photo_book_id }
  validate :photo_is_eligible

  private

  def photo_is_eligible
    return unless photo && photo_book
    return if photo.owner_id == photo_book.owner_id && photo.image? && !photo.restricted? && photo.archived_at.nil?

    errors.add(:photo, "must be an available image belonging to the book owner")
  end
end
