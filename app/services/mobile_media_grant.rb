class MobileMediaGrant
  TTL = 10.minutes
  MAX_TTL = 1.hour
  VARIANTS = %w[thumbnail display video original].freeze

  def self.issue(device:, photo:, variant:, ttl: TTL)
    verifier.generate({ "device_id" => device.id, "photo_id" => photo.id, "variant" => variant },
      purpose: "mobile-media", expires_in: ttl)
  end

  def self.verify(token, photo_id:, variant:)
    return if token.to_s.bytesize > 2048

    payload = verifier.verified(token, purpose: "mobile-media")
    return unless payload.is_a?(Hash) && payload["photo_id"].to_s == photo_id.to_s && payload["variant"] == variant

    device = DeviceSession.includes(:user).find_by(id: payload["device_id"])
    device if device&.active?
  end

  def self.verifier
    Rails.application.message_verifier("mobile-media-v1")
  end
  private_class_method :verifier
end
