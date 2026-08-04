require "test_helper"

class OpenrouterVisionClientTest < ActiveSupport::TestCase
  test "requires a configured API key" do
    error = assert_raises(OpenrouterVisionClient::Error) do
      OpenrouterVisionClient.new(api_key: "").analyze(image_bytes: "jpeg")
    end

    assert_equal "OPENROUTER_API_KEY is not configured", error.message
  end

  test "sends images only to zero retention non collecting providers" do
    client = OpenrouterVisionClient.new(api_key: "secret")
    payload = client.send(
      :request_body,
      image_bytes: "jpeg",
      content_type: "image/jpeg",
      context: { approximate_location: "Petoskey, Michigan", capture_date: "2026-08-04" }
    )

    assert_equal true, payload.dig(:provider, :zdr)
    assert_equal "deny", payload.dig(:provider, :data_collection)
    assert_equal true, payload.dig(:provider, :require_parameters)
    assert_equal "json_schema", payload.dig(:response_format, :type)
    assert_equal true, payload.dig(:response_format, :json_schema, :strict)
    assert_equal false, payload.dig(:response_format, :json_schema, :schema, :additionalProperties)
    assert_equal OpenrouterVisionClient::DEFAULT_MAX_TOKENS, payload.fetch(:max_tokens)
    prompt = payload.dig(:messages, 0, :content, 0, :text)
    assert_includes prompt, "Never state what the image does not contain"
    assert_includes prompt, "omit categories that do not apply"
    assert_includes prompt, "Approximate location: Petoskey, Michigan"
    assert_includes prompt, "Capture date: 2026-08-04"
    assert_includes prompt, "supporting context"
    assert_includes prompt, "Never identify a building"
    assert payload.dig(:messages, 0, :content, 1, :image_url, :url).start_with?("data:image/jpeg;base64,")
  end

  test "treats malformed model JSON as retryable" do
    error = assert_raises(OpenrouterVisionClient::RetryableError) do
      OpenrouterVisionClient.new(api_key: "secret").send(:parse_content, '{"caption":"truncated')
    end

    assert_includes error.message, "was not valid JSON"
    assert_equal '{"caption":"truncated', error.details.fetch("content_preview")
  end

  test "reports empty successful responses with retry diagnostics" do
    response = SuccessfulResponse.new(
      JSON.generate(
        id: "generation-empty",
        model: "qwen/qwen3-vl-30b-a3b-instruct",
        provider: "SiliconFlow",
        choices: [ { finish_reason: "stop", message: { content: "" } } ],
        usage: { prompt_tokens: 2_500, completion_tokens: 0, cost: 0.00075 }
      )
    )
    client = OpenrouterVisionClient.new(api_key: "secret")
    client.define_singleton_method(:perform_request) { |_payload| response }

    error = assert_raises(OpenrouterVisionClient::RetryableError) do
      client.analyze(image_bytes: "jpeg")
    end

    assert_includes error.message, "empty vision content"
    assert_includes error.message, "provider=SiliconFlow"
    assert_equal "generation-empty", error.details.fetch("request_id")
    assert_equal 0.00075, error.details.dig("usage", "cost")
  end

  test "preserves retry after guidance on rate limits" do
    response = ErrorResponse.new(
      JSON.generate(error: { message: "rate limited" }),
      "429",
      { "Retry-After" => "60" }
    )

    error = assert_raises(OpenrouterVisionClient::RetryableError) do
      OpenrouterVisionClient.new(api_key: "secret").send(:parse_response, response)
    end

    assert_equal 60, error.retry_after
  end

  test "normalizes caption tags readable text and usage" do
    response = SuccessfulResponse.new(
      JSON.generate(
        id: "generation-123",
        model: "qwen/qwen3-vl-30b-a3b-instruct",
        provider: "DeepInfra",
        choices: [
          { message: { content: JSON.generate(caption: "A dog sits by a window.", tags: [ "Dog", " window " ], readable_text: [ "OPEN" ]) } }
        ],
        usage: { prompt_tokens: 2_500, completion_tokens: 18, cost: 0.000386 }
      )
    )
    client = OpenrouterVisionClient.new(api_key: "secret")
    client.define_singleton_method(:perform_request) { |_payload| response }

    result = client.analyze(image_bytes: "jpeg")

    assert_equal "A dog sits by a window.", result.fetch("caption")
    assert_equal %w[dog window], result.fetch("tags")
    assert_equal [ "OPEN" ], result.fetch("readable_text")
    assert_equal 2_500, result.fetch("input_tokens")
    assert_equal 0.000386, result.fetch("cost")
  end

  SuccessfulResponse = Struct.new(:body) do
    def is_a?(klass)
      return true if klass == Net::HTTPSuccess

      super
    end

    def code
      "200"
    end
  end

  ErrorResponse = Struct.new(:body, :code, :headers) do
    def is_a?(_klass)
      false
    end

    def message
      "Too Many Requests"
    end

    def [](name)
      headers[name]
    end
  end
end
