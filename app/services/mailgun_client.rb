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
      api_key.present? && domain.present? && sender_address.present?
    end

    def default_from
      address = sender_address!
      return address if address.include?("<")

      %("#{sender_name}" <#{address}>)
    end

    private

    def deliver_via_api(message)
      unless configured?
        raise DeliveryError, "MAILGUN_API_KEY, MAILGUN_DOMAIN, and MAILGUN_FROM or MAILER_SENDER must be configured"
      end

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
      ENV["MAILGUN_API_BASE"].presence || ENV["MAILGUN_API_BASE_URL"].presence || "https://api.mailgun.net"
    end

    def default_headers
      {
        "Reply-To" => ENV["MAILGUN_REPLY_TO"].presence || sender_address!,
        "Auto-Submitted" => "auto-generated",
        "X-Auto-Response-Suppress" => "All"
      }
    end

    def sender_address
      ENV["MAILGUN_FROM"].presence || ENV["MAILER_SENDER"].presence
    end

    def sender_address!
      sender_address || raise(DeliveryError, "MAILGUN_FROM or MAILER_SENDER must be configured")
    end

    def sender_name
      ENV["MAILGUN_FROM_NAME"].presence || ENV["MAILER_SENDER_NAME"].presence || "Photos"
    end

    def mailgun_headers(headers)
      headers.compact_blank.transform_keys { |key| "h:#{key}" }
    end
  end
end
