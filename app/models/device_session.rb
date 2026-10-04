class DeviceSession < ApplicationRecord
  ACCESS_TTL = 30.days
  REFRESH_TTL = 90.days
  PLATFORMS = %w[ios android other].freeze

  belongs_to :user
  has_many :mobile_uploads, dependent: :destroy

  validates :name, presence: true, length: { maximum: 100 }
  validates :platform, inclusion: { in: PLATFORMS }
  validates :token_digest, :refresh_token_digest, :authentication_fingerprint, :expires_at, :refresh_expires_at, presence: true

  def self.issue!(user:, name:, platform:)
    device = new(user: user, name: name, platform: platform, authentication_fingerprint: user.authentication_fingerprint)
    credentials = device.rotate_credentials!
    [ device, credentials ]
  end

  def self.authenticate(token)
    return if token.blank? || token.bytesize > 256

    device = includes(:user).find_by(token_digest: User.digest(token))
    device if device&.active? && device.expires_at.future?
  end

  def active?
    revoked_at.nil? && refresh_expires_at.future? &&
      ActiveSupport::SecurityUtils.secure_compare(authentication_fingerprint, user.authentication_fingerprint)
  end

  def rotate_credentials!
    access_token = SecureRandom.urlsafe_base64(32)
    refresh_token = SecureRandom.urlsafe_base64(32)
    self.refresh_expires_at ||= REFRESH_TTL.from_now
    update!(token_digest: User.digest(access_token), refresh_token_digest: User.digest(refresh_token),
      expires_at: [ ACCESS_TTL.from_now, refresh_expires_at ].min)
    { access_token: access_token, refresh_token: refresh_token, token_type: "Bearer",
      expires_at: expires_at, refresh_expires_at: refresh_expires_at, device_id: id }
  end

  def restricted_unlocked?
    password = ENV["PHOTOS_LOCKED_FOLDER_PASSWORD"].to_s
    user.owner? && password.present? && restricted_unlocked_until&.future? &&
      restricted_password_digest == User.digest(password)
  end

  def revoke!
    update!(revoked_at: Time.current, restricted_unlocked_until: nil, restricted_password_digest: nil)
  end
end
