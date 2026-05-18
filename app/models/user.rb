class User < ApplicationRecord
  ROLES = %w[owner viewer].freeze
  attr_accessor :first_name, :last_name

  has_secure_password validations: false

  has_many :photos, foreign_key: :owner_id, dependent: :restrict_with_exception, inverse_of: :owner
  has_many :photo_albums, foreign_key: :owner_id, dependent: :restrict_with_exception, inverse_of: :owner
  has_many :photo_location_covers, foreign_key: :owner_id, dependent: :destroy, inverse_of: :owner
  has_many :upload_batches, foreign_key: :owner_id, dependent: :restrict_with_exception, inverse_of: :owner
  has_many :album_downloads, dependent: :destroy
  has_many :google_takeout_import_runs, foreign_key: :owner_id, dependent: :restrict_with_exception, inverse_of: :owner
  has_many :sent_invitations, class_name: "User", foreign_key: :invited_by_id, dependent: :nullify, inverse_of: :invited_by
  belongs_to :invited_by, class_name: "User", optional: true
  has_many :photo_people_tags, dependent: :destroy
  has_many :tagged_photos, through: :photo_people_tags, source: :photo
  has_many :photo_album_shares, dependent: :destroy
  has_many :shared_photo_albums, through: :photo_album_shares, source: :photo_album
  has_many :created_photo_album_shares, class_name: "PhotoAlbumShare", foreign_key: :shared_by_id, dependent: :destroy, inverse_of: :shared_by
  has_one_attached :avatar

  normalizes :email, with: ->(email) { email.to_s.strip.downcase }

  validates :provider, :uid, :email, :role, presence: true
  validates :uid, uniqueness: { scope: :provider }
  validates :email, uniqueness: true
  validates :role, inclusion: { in: ROLES }
  validates :password, length: { minimum: 10 }, allow_blank: true

  PASSWORD_RESET_TTL = 2.hours

  def self.from_omniauth(auth)
    user = find_by(provider: auth.provider, uid: auth.uid) || find_or_initialize_by(email: auth.info.email)
    user.provider = auth.provider
    user.uid = auth.uid
    user.email = auth.info.email
    user.name = auth.info.name.presence || auth.info.email
    user.avatar_url = auth.info.image
    user.role = role_for(auth.info.email) if user.new_record?
    if store_google_drive_credentials?(user, auth)
      user.google_access_token = auth.credentials.token
      user.google_refresh_token = auth.credentials.refresh_token.presence || user.google_refresh_token
      user.google_token_expires_at = Time.zone.at(auth.credentials.expires_at) if auth.credentials.expires_at.present?
    end
    user.last_signed_in_at = Time.current
    user.invite_accepted_at ||= Time.current if user.invited?
    user.save!
    user
  end

  def self.invite!(email:, name: nil, invited_by:)
    user = find_or_initialize_by(email: email)
    user.name = name.presence || user.name
    user.provider ||= "password"
    user.uid ||= user.email
    user.role ||= "viewer"
    user.invited_by = invited_by
    user.invited_at ||= Time.current
    user.save!
    user
  end

  def self.authenticate_by_email(email, password)
    user = find_by(email: email)
    return unless user&.authenticate(password)

    user.update!(last_signed_in_at: Time.current, invite_accepted_at: Time.current) if user.invited?
    user
  end

  def self.find_by_password_reset_token(token)
    return if token.blank?

    user = find_by(password_reset_token_digest: digest(token))
    return unless user&.password_reset_valid?

    user
  end

  def google_drive_authorized?
    google_refresh_token.present? || google_access_token.present?
  end

  def owner?
    role == "owner"
  end

  def viewer?
    role == "viewer"
  end

  def trusted_viewer?
    owner? || invite_accepted?
  end

  def invited?
    invited_at.present?
  end

  def invite_accepted?
    invite_accepted_at.present?
  end

  def invited_pending?
    invited? && !invite_accepted?
  end

  def invitation_url_token
    signed_id(purpose: :invitation)
  end

  def generate_password_reset_token!
    token = SecureRandom.urlsafe_base64(32)
    update!(
      password_reset_token_digest: self.class.digest(token),
      password_reset_sent_at: Time.current
    )
    token
  end

  def password_reset_valid?
    password_reset_token_digest.present? &&
      password_reset_sent_at.present? &&
      password_reset_sent_at >= PASSWORD_RESET_TTL.ago
  end

  def reset_password!(attributes)
    self.password = attributes[:password]
    self.password_confirmation = attributes[:password_confirmation]
    self.password_reset_token_digest = nil
    self.password_reset_sent_at = nil
    self.invite_accepted_at ||= Time.current if invited?
    self.provider ||= "password"
    self.uid ||= email
    save!
  end

  def accept_invitation!(password: nil, password_confirmation: nil)
    self.password = password if password.present?
    self.password_confirmation = password_confirmation if password.present?
    self.invite_accepted_at ||= Time.current
    self.provider ||= "password"
    self.uid ||= email
    save!
  end

  def remember!
    token = SecureRandom.urlsafe_base64(32)
    update!(remember_token_digest: self.class.digest(token))
    token
  end

  def forget!
    update!(remember_token_digest: nil)
  end

  def remembered?(token)
    return false if remember_token_digest.blank? || token.blank?

    ActiveSupport::SecurityUtils.secure_compare(remember_token_digest, self.class.digest(token))
  end

  def display_name
    name.presence || email
  end

  def avatar_image
    avatar.attached? ? avatar : avatar_url
  end

  def self.digest(token)
    Digest::SHA256.hexdigest(token.to_s)
  end

  def self.role_for(email)
    email.to_s.casecmp?(ENV["PHOTOS_OWNER_EMAIL"].to_s) ? "owner" : "viewer"
  end

  def self.store_google_drive_credentials?(user, auth)
    user.owner? &&
      auth.credentials.present? &&
      google_drive_scope_granted?(auth.credentials)
  end

  def self.google_drive_scope_granted?(credentials)
    credentials.fetch("scope", credentials[:scope]).to_s.split.include?(GoogleDriveArchiveClient::DRIVE_SCOPE)
  end
  private_class_method :role_for
  private_class_method :store_google_drive_credentials?, :google_drive_scope_granted?
end
