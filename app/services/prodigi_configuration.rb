class ProdigiConfiguration
  ENDPOINTS = { "sandbox" => "https://api.sandbox.prodigi.com/v4.0", "live" => "https://api.prodigi.com/v4.0" }.freeze
  DEFAULT_SKUS = {
    "landscape_a4" => "BOOK-FE-A4-L-LF-G",
    "square_210" => "BOOK-FE-8_3-SQ-LF-G",
    "square_297" => "BOOK-FE-11_7-SQ-LF-G"
  }.freeze

  def self.environment
    ENV.fetch("PRODIGI_ENVIRONMENT", "sandbox")
  end

  def self.api_key(environment)
    raise ProdigiClient::Error, "Choose sandbox or live for PRODIGI_ENVIRONMENT." unless ENDPOINTS.key?(environment)

    ENV["PRODIGI_#{environment.upcase}_API_KEY"].presence || raise(ProdigiClient::Error, "The #{environment} Prodigi API key is not configured.")
  end

  def self.sku(format)
    name = "PRODIGI_SKU_#{format.upcase}"
    ENV[name].presence || DEFAULT_SKUS[format] || raise(ProdigiClient::Error, "Configure #{name} with the layflat product code from your Prodigi catalogue.")
  end

  def self.public_base_url
    base_url = ENV["PRODIGI_PUBLIC_BASE_URL"].presence
    base_url ||= "https://#{ENV['PHOTOS_HOST']}" if ENV["PHOTOS_HOST"].present?
    uri = URI.parse(base_url.to_s)
    unless uri.is_a?(URI::HTTPS) && uri.host.present? && uri.userinfo.nil? && uri.query.nil? && uri.fragment.nil? && [ "", "/" ].include?(uri.path)
      raise ProdigiClient::Error, "Set PHOTOS_HOST to the public hostname of Photos, or override it with PRODIGI_PUBLIC_BASE_URL (HTTPS only)."
    end
    uri.to_s.delete_suffix("/")
  rescue URI::InvalidURIError
    raise ProdigiClient::Error, "Set PHOTOS_HOST to the public hostname of Photos, or override it with PRODIGI_PUBLIC_BASE_URL (HTTPS only)."
  end

  def self.webhook_url(environment = self.environment)
    secret = ENV["PRODIGI_WEBHOOK_SECRET"].to_s
    raise ProdigiClient::Error, "Configure PRODIGI_WEBHOOK_SECRET with at least 32 random characters." if secret.length < 32
    raise ProdigiClient::Error, "Choose sandbox or live for PRODIGI_ENVIRONMENT." unless ENDPOINTS.key?(environment)

    "#{public_base_url}/webhooks/prodigi/#{environment}?#{URI.encode_www_form(token: secret)}"
  end

  def self.allow_submission!(environment)
    api_key(environment)
    webhook_url(environment)
    if environment == "live" && ENV["PRODIGI_LIVE_ORDERING_ENABLED"] != "true"
      raise ProdigiClient::Error, "Live ordering is disabled. Enable it on the server after testing the sandbox."
    end
  end
end
