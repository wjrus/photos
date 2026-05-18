require "net/http"

class PhotoAnalysisLocalClient
  Error = Class.new(StandardError)

  DEFAULT_TIMEOUT = 30

  def initialize(base_url: ENV.fetch("ANALYSIS_LOCAL_CONTAINER_URL", "http://analysis-local:8000"), timeout: DEFAULT_TIMEOUT)
    @base_uri = URI(base_url)
    @timeout = timeout
  end

  def health
    get_json("/health")
  end

  def openclip_embed(photo_id:, image_path:, source_variant:)
    post_json("/openclip/embed", photo_id: photo_id, image_path: image_path, source_variant: source_variant)
  end

  def openclip_search(query:, limit: 25)
    post_json("/openclip/search", query: query, limit: limit)
  end

  def yolo_detect(photo_id:, image_path:, source_variant:)
    post_json("/yolo/detect", photo_id: photo_id, image_path: image_path, source_variant: source_variant)
  end

  private

  attr_reader :base_uri, :timeout

  def get_json(path)
    request = Net::HTTP::Get.new(uri_for(path))
    perform(request)
  end

  def post_json(path, payload)
    request = Net::HTTP::Post.new(uri_for(path))
    request["Content-Type"] = "application/json"
    request.body = JSON.generate(payload)
    perform(request)
  end

  def perform(request)
    response = Net::HTTP.start(request.uri.hostname, request.uri.port, use_ssl: request.uri.scheme == "https", open_timeout: timeout, read_timeout: timeout) do |http|
      http.request(request)
    end

    body = response.body.present? ? JSON.parse(response.body) : {}
    return body if response.is_a?(Net::HTTPSuccess)

    raise Error, body.fetch("detail", "Local analysis request failed with HTTP #{response.code}")
  rescue JSON::ParserError => error
    raise Error, "Local analysis returned invalid JSON: #{error.message}"
  end

  def uri_for(path)
    base_uri.merge(path)
  end
end
