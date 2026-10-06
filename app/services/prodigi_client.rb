require "net/http"

class ProdigiClient
  class Error < StandardError; end

  def initialize(environment: ProdigiConfiguration.environment)
    @environment = environment
    @api_key = ProdigiConfiguration.api_key(environment)
  end

  def product(sku)
    raise Error, "Invalid Prodigi product code." unless /\A[A-Z0-9-]{1,100}\z/.match?(sku)

    object_response(request(:get, "/products/#{sku}"), "product")
  end

  def quote(payload)
    request(:post, "/quotes", payload)
  end

  def spine(payload)
    result = request(:post, "/products/spine", payload)
    raise Error, "Prodigi could not calculate the spine size for this book." unless result["success"] == true

    Float(result.fetch("spineInfo").fetch("widthMm"))
  rescue ArgumentError, TypeError, KeyError
    raise Error, "Prodigi returned an invalid spine size."
  end

  def create_order(payload)
    object_response(request(:post, "/orders", payload), "order")
  end

  def order(id)
    raise Error, "Invalid Prodigi order identifier." unless /\Aord_[a-zA-Z0-9_-]{1,100}\z/.match?(id.to_s)

    object_response(request(:get, "/orders/#{id}"), "order")
  end

  private

  def object_response(response, key)
    raise Error, "Prodigi returned invalid #{key} information." unless response[key].is_a?(Hash)

    response.fetch(key)
  end

  def request(method, path, payload = nil)
    uri = URI("#{ProdigiConfiguration::ENDPOINTS.fetch(@environment)}#{path}")
    request = (method == :get ? Net::HTTP::Get : Net::HTTP::Post).new(uri)
    request["X-API-Key"] = @api_key
    request["Content-Type"] = "application/json"
    request["Accept"] = "application/json"
    request.body = JSON.generate(payload) if payload
    response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, open_timeout: 5, read_timeout: 20, write_timeout: 20) { |http| http.request(request) }
    # API errors can contain artwork URLs and delivery addresses. Never log or
    # expose response bodies, including errors from malformed requests.
    raise Error, "Prodigi returned HTTP #{response.code}. Please check the account configuration and try again." unless response.is_a?(Net::HTTPSuccess)

    result = JSON.parse(response.body)
    raise Error, "Prodigi returned an unsuccessful response." unless result.is_a?(Hash) && (result["success"] == true || %w[Ok Created CreatedWithIssues].include?(result["outcome"]))

    result
  rescue JSON::ParserError, KeyError, TypeError
    raise Error, "Prodigi returned an invalid response."
  rescue Timeout::Error, SocketError, IOError, SystemCallError, OpenSSL::SSL::SSLError
    raise Error, "Could not reach Prodigi. An order may still have been received; retrying the same order is safe."
  end
end
