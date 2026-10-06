require "net/http"

class ProdigiClient
  class Error < StandardError; end
  class RequestError < Error; end

  VALIDATION_FIELDS = %w[shippingMethod destinationCountryCode currencyCode items sku copies attributes assets printArea pageCount sizing url
    recipient name email phoneNumber address line1 line2 postalOrZipCode countryCode townOrCity stateOrCounty
    merchantReference idempotencyKey callbackUrl numberOfPages state].freeze

  def initialize(environment: ProdigiConfiguration.environment)
    @environment = environment
    @api_key = ProdigiConfiguration.api_key(environment)
  end

  def product(sku)
    raise Error, "Invalid Prodigi product code." unless /\A[A-Z0-9_-]{1,100}\z/.match?(sku)

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
    sandbox_log("request", method: method, path: path, data: diagnostic_request(payload))
    response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, open_timeout: 5, read_timeout: 20, write_timeout: 20) { |http| http.request(request) }
    sandbox_log("response", method: method, path: path, http_status: response.code)
    raise_http_error(response, method, path) unless response.is_a?(Net::HTTPSuccess)

    result = JSON.parse(response.body)
    raise Error, "Prodigi returned an unsuccessful response." unless result.is_a?(Hash) && (result["success"] == true || %w[Ok Created CreatedWithIssues].include?(result["outcome"]))

    sandbox_log("response_data", method: method, path: path, data: diagnostic_response(result))
    result
  rescue JSON::ParserError, KeyError, TypeError
    raise Error, "Prodigi returned an invalid response."
  rescue Timeout::Error, SocketError, IOError, SystemCallError, OpenSSL::SSL::SSLError
    raise Error, "Could not reach Prodigi. An order may still have been received; retrying the same order is safe."
  end

  def raise_http_error(response, method, path)
    # Error messages can echo addresses, secrets, and signed URLs. Extract only
    # recognised field paths and a strictly validated vendor support trace.
    details = error_details(response)
    sandbox_log("response_error", method: method, path: path, http_status: response.code, data: details)
    operation = { "/orders" => "order submission", "/quotes" => "price quote", "/products/spine" => "spine calculation" }.fetch(path, "API request")
    message = "Prodigi rejected the #{operation} (HTTP #{response.code})."
    message += " Check the API key for this environment." if %w[401 403].include?(response.code)
    message += " Validation fields: #{details.fetch('fields').join(', ')}." if details["fields"].present?
    message += " Support trace: #{details['traceParent']}." if details["traceParent"]
    error_class = response.code.start_with?("4") && !%w[408 429].include?(response.code) ? RequestError : Error
    raise error_class, message
  end

  def error_details(response)
    body = response.body.to_s
    result = begin
      body.bytesize <= 64.kilobytes ? JSON.parse(body) : {}
    rescue JSON::ParserError
      {}
    end
    result = {} unless result.is_a?(Hash)
    trace = [ response["traceParent"], result["traceParent"] ].find do |candidate|
      candidate.is_a?(String) && /\A[0-9a-f]{2}-[0-9a-f]{32}-[0-9a-f]{16}-[0-9a-f]{2}\z/i.match?(candidate)
    end
    details = { "fields" => validation_fields(result["data"] || result["errors"]) }
    details["traceParent"] = trace if trace
    details
  end

  def validation_fields(value, depth = 0)
    return [] if depth > 6

    case value
    when Hash
      value.first(80).flat_map do |key, child|
        fields = safe_field_path(key) ? [ key ] : []
        fields << child if %w[field property propertyName].include?(key) && safe_field_path(child)
        fields + validation_fields(child, depth + 1)
      end.uniq
    when Array then value.first(10).flat_map { |child| validation_fields(child, depth + 1) }.uniq
    else []
    end
  end

  def safe_field_path(value)
    return false unless value.is_a?(String) && value.length <= 200
    return false unless /\A(?:\$\.)?[a-zA-Z]+(?:\[\d{1,3}\])?(?:\.[a-zA-Z]+(?:\[\d{1,3}\])?)*\z/.match?(value)

    value.scan(/[a-zA-Z]+/).all? { |part| VALIDATION_FIELDS.any? { |field| field.casecmp?(part) } }
  end

  # Sandbox diagnostics are an allowlist: vendor responses can echo delivery
  # details, API keys, and signed artwork URLs even in their error messages.
  def sandbox_log(event, **details)
    return unless @environment == "sandbox"

    Rails.logger.info { "Prodigi sandbox #{JSON.generate({ event: event }.merge(details))}" }
  end

  def diagnostic_request(payload)
    return unless @environment == "sandbox" && payload

    payload.slice("sku", "shippingMethod", "currencyCode", "numberOfPages").merge(
      "items" => Array(payload["items"]).map do |item|
        item.slice("sku", "copies").merge("assets" => Array(item["assets"]).map { |asset| asset.slice("printArea", "pageCount") })
      end)
  end

  def diagnostic_response(result)
    return unless @environment == "sandbox"

    data = result.slice("outcome", "success")
    if result["product"].is_a?(Hash)
      product = result.fetch("product")
      data["product"] = product.slice("sku", "productDimensions", "printAreas")
    end
    data["spineInfo"] = result["spineInfo"].slice("widthMm") if result["spineInfo"].is_a?(Hash)
    if result["quotes"].is_a?(Array)
      data["quotes"] = result["quotes"].map do |quote|
        quote.slice("shipmentMethod").merge("costSummary" => quote.fetch("costSummary", {}).slice("items", "shipping").transform_values { |cost| cost.slice("amount", "currency") })
      end
    end
    if result["order"].is_a?(Hash)
      data["order"] = result["order"].slice("id").merge("stage" => result["order"].dig("status", "stage"))
    end
    data
  end
end
