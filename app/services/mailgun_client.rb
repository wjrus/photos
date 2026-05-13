require "net/http"

class MailgunClient
  class DeliveryError < StandardError; end

  Message = Data.define(:to, :subject, :text, :html, :from, :headers)

  class << self
    def deliveries
      @deliveries ||= []
    end

    def clear_deliveries
      deliveries.clear
    end

    def deliver(to:, subject:, text:, html: nil, from: default_from, headers: {})
      message = Message.new(
        to: to,
        subject: subject,
        text: text,
        html: html,
        from: from,
        headers: default_headers.merge(headers)
      )

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
      address = ENV.fetch("MAILGUN_FROM", "photos@example.com")
      return address if address.include?("<")

      %("#{ENV.fetch('MAILGUN_FROM_NAME', 'Photos')}" <#{address}>)
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
        }.compact.merge(mailgun_headers(message.headers)),
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
      ENV["MAILGUN_DOMAIN"].to_s
    end

    def api_base
      ENV.fetch("MAILGUN_API_BASE", "https://api.mailgun.net")
    end

    def default_headers
      {
        "Reply-To" => ENV.fetch("MAILGUN_REPLY_TO", ENV.fetch("MAILGUN_FROM", "photos@example.com")),
        "Auto-Submitted" => "auto-generated",
        "X-Auto-Response-Suppress" => "All"
      }
    end

    def mailgun_headers(headers)
      headers.compact_blank.transform_keys { |key| "h:#{key}" }
    end
  end
end
