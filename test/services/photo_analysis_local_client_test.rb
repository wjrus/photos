require "test_helper"

class PhotoAnalysisLocalClientTest < ActiveSupport::TestCase
  test "includes non json error responses in local analysis failures" do
    response = Struct.new(:code, :message, :body).new("500", "Internal Server Error", "Internal Server Error")

    with_http_response(response) do
      error = assert_raises(PhotoAnalysisLocalClient::Error) do
        PhotoAnalysisLocalClient.new(base_url: "http://analysis-local:8000").health
      end

      assert_includes error.message, "HTTP 500"
      assert_includes error.message, "Internal Server Error"
    end
  end

  private

  def with_http_response(response)
    original_start = Net::HTTP.method(:start)
    Net::HTTP.define_singleton_method(:start) { |*_args, **_kwargs, &_block| response }
    yield
  ensure
    Net::HTTP.define_singleton_method(:start, original_start)
  end
end
