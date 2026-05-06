class User < ApplicationRecord
  ROLES = %w[owner viewer].freeze
  attr_accessor :first_name, :last_name

  has_secure_password validations: false

  has_many :photos, foreign_key: :owner_id, dependent: :restrict_with_exception, inverse_of: :owner
  has_many :photo_albums, foreign_key: :owner_id, dependent: :restrict_with_exception, inverse_of: :owner
  has_many :photo_location_covers, foreign_key: :owner_id, dependent: :destroy, inverse_of: :owner
  has_many :upload_batches, foreign_key: :owner_id, dependent: :restrict_with_exception, inverse_of: :owner
  has_many :google_takeout_import_runs, foreign_key: :owner_id, dependent: :restrict_with_exception, inverse_of: :owner
  has_many :sent_invitations, class_name: "User", foreign_key: :invited_by_id, dependent: :nullify, inverse_of: :invited_by
  belongs_to :invited_by, class_name: "User", optional: true
  has_many :photo_people_tags, dependent: :destroy
  has_many :tagged_photos, through: :photo_people_tags, source: :photo
  has_one_attached :avatar

  normalizes :email, with: ->(email) { email.to_s.strip.downcase }

  validates :provider, :uid, :email, :role, presence: true
  validates :uid, uniqueness: { scope: :provider }
  validates :email, uniqueness: true
  validates :role, inclusion: { in: ROLES }
  validates :password, length: { minimum: 10 }, allow_blank: true

  def self.from_omniauth(auth)
    user = find_by(provider: auth.provider, uid: auth.uid) || find_or_initialize_by(email: auth.info.email)
    user.provider = auth.provider
    user.uid = auth.uid
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

  def google_drive_authorized?
    google_refresh_token.present? || google_access_token.present?
  end

  def owner?
    role == "owner"
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
  private_class_method :role_for
end
