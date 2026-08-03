class AlbumAccessLink < ApplicationRecord
  belongs_to :photo_album
  belongs_to :created_by, class_name: "User", inverse_of: :created_album_access_links

  validates :label, presence: true, length: { maximum: 80 }
  validates :access_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validate :expiration_must_be_in_the_future, on: :create

  scope :recent_first, -> { order(created_at: :desc, id: :desc) }

  def self.authenticate(album:, key:)
    return if key.blank?

    link = find_signed(key, purpose: :album_access)
    link if link&.photo_album_id == album.id && link.active?
  end

  def key
    options = { purpose: :album_access }
    options[:expires_at] = expires_at if expires_at.present?
    signed_id(**options)
  end

  def active?
    revoked_at.nil? && (expires_at.nil? || expires_at.future?)
  end

  def revoked?
    revoked_at.present?
  end

  def expired?
    expires_at.present? && expires_at.past?
  end

  def revoke!
    update!(revoked_at: Time.current) unless revoked?
  end

  def record_access!
    self.class.where(id: id).update_all([
      "access_count = access_count + 1, last_accessed_at = ?",
      Time.current
    ])
    reload
  end

  private

  def expiration_must_be_in_the_future
    errors.add(:expires_at, "must be in the future") if expires_at.present? && !expires_at.future?
  end
end
