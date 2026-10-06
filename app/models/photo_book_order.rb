class PhotoBookOrder < ApplicationRecord
  SHIPPING_METHODS = %w[Budget Standard StandardPlus Express Overnight].freeze
  CURRENCIES = %w[USD GBP EUR CAD AUD].freeze
  RECIPIENT_FIELDS = %w[name email phoneNumber].freeze
  ADDRESS_FIELDS = %w[line1 line2 postalOrZipCode countryCode townOrCity stateOrCounty].freeze
  FROZEN_FIELDS = %w[photo_book_export_id environment reference sku copies shipping_method currency recipient quote product quoted_at request_payload approved_at asset_expires_at].freeze

  belongs_to :photo_book_export
  has_one :photo_book, through: :photo_book_export
  has_one_attached :spine_document
  before_validation -> { self.reference ||= SecureRandom.uuid }, on: :create
  before_validation :normalize_recipient, on: :create
  validates :reference, :sku, presence: true
  validates :environment, inclusion: { in: ProdigiConfiguration::ENDPOINTS.keys }
  validates :status, inclusion: { in: %w[draft quoted submitting submitted] }
  validates :copies, numericality: { only_integer: true, in: 1..10 }
  validates :shipping_method, inclusion: { in: SHIPPING_METHODS }
  validates :currency, inclusion: { in: CURRENCIES }
  validate :valid_recipient
  validate :approved_order_is_immutable, on: :update

  def page_count
    PhotoBookLayout.new(photo_book_export.snapshot).pages.size
  end

  def quote_current?
    status == "quoted" && quoted_at.present? && quoted_at > 1.hour.ago
  end

  def artwork_available?
    photo_book_export.ready? && photo_book_export.source_photos_available?
  end

  def item
    { "sku" => sku, "copies" => copies, "attributes" => product.fetch("selectedAttributes", {}),
      "assets" => [ { "printArea" => "default", "pageCount" => page_count } ] + (spine_document.attached? ? [ { "printArea" => "spine" } ] : []) }
  end

  def quote_total
    %w[items shipping].sum { |key| BigDecimal(quote.fetch("costSummary").fetch(key).fetch("amount")) }
  end

  def quote_digest
    Digest::SHA256.hexdigest([ reference, quoted_at&.iso8601(6), quote, recipient, copies, sku ].to_json)
  end

  # Approval freezes both the reviewed price and the exact idempotent request.
  # No network call occurs under this transaction; the durable job does that.
  def approve!(reviewed_quote:)
    with_lock do
      return false if approved_at.present?

      raise ProdigiClient::Error, "Refresh the quote before confirming this order." unless quote_current?
      raise ProdigiClient::Error, "The quote changed. Review its current price before confirming." unless reviewed_quote == quote_digest
      raise ProdigiClient::Error, "The PDF or its source photos are no longer available." unless artwork_available?
      ProdigiConfiguration.allow_submission!(environment)
      self.approved_at = Time.current
      self.asset_expires_at = 30.days.from_now
      token = signed_id(purpose: :prodigi_artwork, expires_at: asset_expires_at)
      assets = item.fetch("assets").map do |asset|
        asset.merge("url" => "#{ProdigiConfiguration.public_base_url}/print_assets/#{id}/#{asset.fetch('printArea')}?#{URI.encode_www_form(token: token)}")
      end
      self.request_payload = { "merchantReference" => reference, "idempotencyKey" => reference,
        "callbackUrl" => ProdigiConfiguration.webhook_url(environment), "shippingMethod" => shipping_method, "recipient" => recipient,
        "items" => [ item.merge("assets" => assets, "sizing" => "fillPrintArea") ] }
      self.status = "submitting"
      self.error = nil
      save!
      true
    end
  end

  def record_remote!(data)
    id = data.fetch("id")
    raise ProdigiClient::Error, "Prodigi returned an invalid order identifier." unless /\Aord_[a-zA-Z0-9_-]{1,100}\z/.match?(id.to_s)
    if data["merchantReference"].present? && data["merchantReference"] != reference
      raise ProdigiClient::Error, "Prodigi returned a different order."
    end
    updated = Time.iso8601(data["lastUpdated"]) if data["lastUpdated"].present?
    with_lock do
      raise ProdigiClient::Error, "Prodigi returned a different order." if remote_id.present? && remote_id != id
      return if updated && remote_updated_at && updated < remote_updated_at

      self.remote_id = id
      self.status = "submitted"
      # Keep status locally without copying the recipient or signed artwork URLs
      # back from the vendor response.
      self.remote_status = data.fetch("status", {}).slice("stage", "details").merge(
        "hasIssues" => data.dig("status", "issues").present?,
        "shipments" => Array(data["shipments"]).map { |shipment| shipment.slice("id", "status", "tracking") })
      self.remote_updated_at = updated if updated
      self.refreshed_at = Time.current
      self.error = nil
      save!
    end
  rescue KeyError, ArgumentError, TypeError
    raise ProdigiClient::Error, "Prodigi returned invalid order status."
  end

  private

  def normalize_recipient
    return unless recipient.is_a?(Hash) && recipient["address"].is_a?(Hash)

    recipient.except("address").each { |key, value| recipient[key] = value.strip if value.is_a?(String) }
    recipient["address"].each { |key, value| recipient["address"][key] = value.strip if value.is_a?(String) }
    recipient["address"]["countryCode"] = recipient["address"]["countryCode"].upcase if recipient["address"]["countryCode"].is_a?(String)
  end

  def valid_recipient
    unless recipient.is_a?(Hash) && recipient["address"].is_a?(Hash)
      return errors.add(:recipient, "must include a delivery address")
    end
    address = recipient.fetch("address")
    errors.add(:recipient, "contains unsupported fields") if (recipient.keys - RECIPIENT_FIELDS - [ "address" ]).any? || (address.keys - ADDRESS_FIELDS).any?
    { "name" => recipient["name"], "address line 1" => address["line1"], "postal code" => address["postalOrZipCode"], "city" => address["townOrCity"] }.each do |label, value|
      errors.add(:recipient, "#{label} is required") if value.blank?
    end
    (recipient.except("address").values + address.values).each do |value|
      errors.add(:recipient, "fields must be text of at most 200 characters") unless value.is_a?(String) && value.length <= 200
    end
    errors.add(:recipient, "country must be a two-letter code") unless /\A[A-Z]{2}\z/.match?(address["countryCode"].to_s)
    errors.add(:recipient, "state is required for US deliveries") if address["countryCode"] == "US" && address["stateOrCounty"].blank?
    errors.add(:recipient, "email is invalid") if recipient["email"].present? && (!recipient["email"].is_a?(String) || !URI::MailTo::EMAIL_REGEXP.match?(recipient["email"]))
  end

  def approved_order_is_immutable
    if approved_at_in_database && (changes.keys & FROZEN_FIELDS).any?
      errors.add(:base, "A confirmed order cannot be changed. Create a new order for a different design or address.")
    end
  end
end
