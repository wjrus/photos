class User < ApplicationRecord
  ROLES = %w[owner viewer].freeze

  has_many :photos, foreign_key: :owner_id, dependent: :restrict_with_exception, inverse_of: :owner

  normalizes :email, with: ->(email) { email.to_s.strip.downcase }

  validates :provider, :uid, :email, :role, presence: true
  validates :uid, uniqueness: { scope: :provider }
  validates :role, inclusion: { in: ROLES }

  def self.from_omniauth(auth)
    user = find_or_initialize_by(provider: auth.provider, uid: auth.uid)
    user.email = auth.info.email
    user.name = auth.info.name.presence || auth.info.email
    user.avatar_url = auth.info.image
    if auth.credentials.present?
      user.google_access_token = auth.credentials.token
      user.google_refresh_token = auth.credentials.refresh_token.presence || user.google_refresh_token
      user.google_token_expires_at = Time.zone.at(auth.credentials.expires_at) if auth.credentials.expires_at.present?
    end
    user.role = role_for(auth.info.email) if user.new_record?
    user.last_signed_in_at = Time.current
    user.save!
    user
  end

  def google_drive_authorized?
    google_refresh_token.present? || google_access_token.present?
  end

  def owner?
    role == "owner"
  end

  def display_name
    name.presence || email
  end

  def self.role_for(email)
    email.to_s.casecmp?(ENV["PHOTOS_OWNER_EMAIL"].to_s) ? "owner" : "viewer"
  end
  private_class_method :role_for
end
