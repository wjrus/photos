class AlbumAccessLink < ApplicationRecord
  KEY_LENGTH = 16

  belongs_to :photo_album
  belongs_to :created_by, class_name: "User", inverse_of: :created_album_access_links

  validates :label, presence: true, length: { maximum: 80 }
  validates :access_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validate :expiration_must_be_in_the_future, on: :create

  scope :recent_first, -> { order(created_at: :desc, id: :desc) }

  def self.authenticate(album:, key:)
    return if key.blank?

    link = authenticate_short_key(album, key) || authenticate_legacy_key(key)
    link if link&.photo_album_id == album.id && link.active?
  end

  def key
    digest = OpenSSL::HMAC.digest("SHA256", self.class.key_secret, id.to_s)
    Base64.urlsafe_encode64(digest, padding: false).first(KEY_LENGTH)
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

  def self.authenticate_short_key(album, key)
    return unless key.bytesize == KEY_LENGTH

    album.album_access_links.find_each do |link|
      return link if ActiveSupport::SecurityUtils.secure_compare(link.key, key)
    end

    nil
  end

  def self.authenticate_legacy_key(key)
    find_signed(key, purpose: :album_access)
  end

  def self.key_secret
    @key_secret ||= Rails.application.key_generator.generate_key("album-access-link", 32)
  end

  def expiration_must_be_in_the_future
    errors.add(:expires_at, "must be in the future") if expires_at.present? && !expires_at.future?
  end
end
