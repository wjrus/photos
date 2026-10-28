require "net/http"
require "time"

# Both geocoding and Nearby Search are read-only, so transient failures can be
# retried. Reserve every attempt explicitly; Net::HTTP's own retries are off.
class LocationApiRequest
  MAX_ATTEMPTS = 3
  TRANSIENT_STATUSES = %w[408 500 502 503 504].freeze
  TRANSIENT_ERRORS = [ Timeout::Error, SocketError, EOFError, Net::HTTPBadResponse,
    Errno::ECONNRESET, Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ENETUNREACH,
    Errno::ETIMEDOUT, Errno::EPIPE ].freeze

  def self.perform(kind:, uri:, request:, read_timeout:)
    attempts = 0
    loop do
      attempts += 1
      response = nil
      begin
        LocationApiBudget.reserve!(kind)
        response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 5, read_timeout: read_timeout, max_retries: 0) { |http| http.request(request) }
      rescue *TRANSIENT_ERRORS
        raise if attempts >= MAX_ATTEMPTS
      else
        return response unless TRANSIENT_STATUSES.include?(response.code) && attempts < MAX_ATTEMPTS
      end

      provider_delay = retry_after_seconds(response)
      return response if provider_delay > 30

      sleep([ 2**(attempts - 1), provider_delay ].max + rand * 0.25)
    end
  end

  def self.retry_after_seconds(response)
    value = response&.[]("Retry-After")
    return 0 if value.blank?

    [ value.match?(/\A\d+\z/) ? value.to_i : Time.httpdate(value) - Time.now, 0 ].max
  rescue ArgumentError
    0
  end
  private_class_method :retry_after_seconds
end
