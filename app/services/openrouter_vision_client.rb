require "base64"
require "json"
require "net/http"

class OpenrouterVisionClient
  class Error < StandardError; end
  class RetryableError < Error; end

  ENDPOINT = URI("https://openrouter.ai/api/v1/chat/completions")
  DEFAULT_MODEL = "qwen/qwen3-vl-30b-a3b-instruct".freeze
  DEFAULT_MAX_TOKENS = 480
  DEFAULT_PROMPT = <<~PROMPT.strip.freeze
    Describe the image accurately in 1-2 natural sentences. Mention people, setting, actions, notable objects, and clearly readable text only when they are visibly present. Never state what the image does not contain, and omit categories that do not apply. Do not speculate, identify people by name, or infer sensitive traits.

    Return JSON with exactly these fields:
    - caption: the 1-2 sentence description
    - tags: an array of up to 12 short, lowercase visual search terms
    - readable_text: an array of short strings that are clearly readable in the image
  PROMPT

  attr_reader :model

  def initialize(
    api_key: ENV["OPENROUTER_API_KEY"],
    model: ENV.fetch("OPENROUTER_VISION_MODEL", DEFAULT_MODEL),
    prompt: ENV.fetch("OPENROUTER_VISION_PROMPT", DEFAULT_PROMPT),
    open_timeout: ENV.fetch("OPENROUTER_OPEN_TIMEOUT", 10).to_i,
    read_timeout: ENV.fetch("OPENROUTER_READ_TIMEOUT", 120).to_i
  )
    @api_key = api_key.to_s
    @model = model
    @prompt = prompt
    @open_timeout = open_timeout
    @read_timeout = read_timeout
  end

  def configured?
    @api_key.present?
  end

  def analyze(image_bytes:, content_type: "image/jpeg", context: {})
    raise Error, "OPENROUTER_API_KEY is not configured" unless configured?

    response = perform_request(request_body(image_bytes:, content_type:, context:))
    body = parse_response(response)
    result = parse_content(body.dig("choices", 0, "message", "content"))
    usage = body.fetch("usage", {})

    {
      "request_id" => body["id"],
      "model" => body["model"].presence || model,
      "provider" => body["provider"],
      "caption" => result.fetch("caption").to_s.strip,
      "tags" => Array(result["tags"]).filter_map { |tag| tag.to_s.strip.downcase.presence }.uniq.first(12),
      "readable_text" => Array(result["readable_text"]).filter_map { |text| text.to_s.strip.presence }.uniq.first(20),
      "input_tokens" => usage["prompt_tokens"],
      "output_tokens" => usage["completion_tokens"],
      "cost" => usage["cost"],
      "raw" => body
    }.tap do |normalized|
      raise RetryableError, "OpenRouter response did not include a caption" if normalized.fetch("caption").blank?
    end
  end

  private

  def request_body(image_bytes:, content_type:, context: {})
    {
      model: model,
      messages: [
        {
          role: "user",
          content: [
            { type: "text", text: prompt_with_context(context) },
            {
              type: "image_url",
              image_url: { url: "data:#{content_type};base64,#{Base64.strict_encode64(image_bytes)}" }
            }
          ]
        }
      ],
      temperature: 0.1,
      max_tokens: ENV.fetch("OPENROUTER_MAX_TOKENS", DEFAULT_MAX_TOKENS).to_i,
      response_format: {
        type: "json_schema",
        json_schema: {
          name: "photo_vision_caption",
          strict: true,
          schema: {
            type: "object",
            properties: {
              caption: {
                type: "string",
                description: "An accurate 1-2 sentence description mentioning only content visibly present in the image, without statements about absent content."
              },
              tags: {
                type: "array",
                description: "Up to 12 short lowercase visual search terms.",
                maxItems: 12,
                items: { type: "string" }
              },
              readable_text: {
                type: "array",
                description: "Short strings that are clearly readable in the image.",
                maxItems: 20,
                items: { type: "string" }
              }
            },
            required: %w[caption tags readable_text],
            additionalProperties: false
          }
        }
      },
      usage: { include: true },
      provider: {
        zdr: true,
        data_collection: "deny",
        require_parameters: true
      }
    }
  end

  def prompt_with_context(context)
    context = context.to_h.compact_blank
    return @prompt if context.empty?

    lines = context.map { |key, value| "- #{key.to_s.humanize}: #{value}" }
    <<~PROMPT.strip
      #{@prompt}

      Known photo metadata:
      #{lines.join("\n")}

      Use this metadata only as supporting context when it helps describe visible content. Do not repeat metadata mechanically, and do not let it override the image.
    PROMPT
  end

  def perform_request(payload)
    request = Net::HTTP::Post.new(ENDPOINT)
    request["Authorization"] = "Bearer #{@api_key}"
    request["Content-Type"] = "application/json"
    request["HTTP-Referer"] = ENV.fetch("PHOTOS_ORIGIN", "https://#{ENV.fetch('PHOTOS_HOST', 'photos.wjr.us')}")
    request["X-Title"] = "wjr photos"
    request.body = JSON.generate(payload)

    Net::HTTP.start(
      ENDPOINT.host,
      ENDPOINT.port,
      use_ssl: true,
      open_timeout: @open_timeout,
      read_timeout: @read_timeout
    ) { |http| http.request(request) }
  rescue Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNRESET, Errno::ECONNREFUSED, SocketError => error
    raise RetryableError, "OpenRouter request failed: #{error.message}"
  end

  def parse_response(response)
    body = JSON.parse(response.body)
    return body if response.is_a?(Net::HTTPSuccess)

    message = body.dig("error", "message").presence || response.message
    error_class = response.code.to_i == 429 || response.code.to_i >= 500 ? RetryableError : Error
    raise error_class, "OpenRouter returned HTTP #{response.code}: #{message}"
  rescue JSON::ParserError => error
    error_class = response.code.to_i >= 500 ? RetryableError : Error
    raise error_class, "OpenRouter returned invalid JSON (HTTP #{response.code}): #{error.message}"
  end

  def parse_content(content)
    text = if content.is_a?(Array)
      content.filter_map { |part| part["text"] if part.is_a?(Hash) }.join
    else
      content.to_s
    end
    text = text.sub(/\A```(?:json)?\s*/i, "").sub(/\s*```\z/, "")
    JSON.parse(text)
  rescue JSON::ParserError => error
    raise RetryableError, "OpenRouter vision response was not valid JSON: #{error.message}"
  end
end
