require "net/http"

class MailgunClient
  class DeliveryError < StandardError; end

  Message = Data.define(:to, :subject, :text, :html, :from)

  class << self
    def deliveries
      @deliveries ||= []
    end

    def clear_deliveries
      deliveries.clear
    end

    def deliver(to:, subject:, text:, html: nil, from: default_from)
      message = Message.new(to: to, subject: subject, text: text, html: html, from: from)

      if Rails.env.test?
        deliveries << message
        return message
      end

      deliver_via_api(message)
      message
    end

    def configured?
      api_key.present? && domain.present?
    end

    def default_from
      ENV.fetch("MAILGUN_FROM", "wjrphotos@modes.club")
    end

    private

    def deliver_via_api(message)
      raise DeliveryError, "MAILGUN_API_KEY and MAILGUN_DOMAIN must be configured" unless configured?

      uri = URI.join(api_base, "/v3/#{domain}/messages")
      request = Net::HTTP::Post.new(uri)
      request.basic_auth("api", api_key)
      request.set_form(
        {
          "from" => message.from,
          "to" => message.to,
          "subject" => message.subject,
          "text" => message.text,
          "html" => message.html
        }.compact,
        "multipart/form-data"
      )

      response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https") do |http|
        http.request(request)
      end

      return if response.is_a?(Net::HTTPSuccess)

      raise DeliveryError, "Mailgun delivery failed with #{response.code}: #{response.body}"
    end

    def api_key
      ENV["MAILGUN_API_KEY"].presence
    end

    def domain
      ENV.fetch("MAILGUN_DOMAIN", "modes.club")
    end

    def api_base
      ENV.fetch("MAILGUN_API_BASE", "https://api.mailgun.net")
    end
  end
end
