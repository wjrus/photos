require "test_helper"

class BotProbeFilterTest < ActionDispatch::IntegrationTest
  setup do
    @cache_store = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
  end

  teardown do
    Rails.cache = @cache_store
  end

  test "scanner archive probes short circuit before routing exceptions" do
    get "/backup.zip"

    assert_response :not_found
    assert_equal "text/plain; charset=utf-8", response.content_type
    assert_equal "noindex, nofollow", response.headers["X-Robots-Tag"]
    assert_equal "Not found\n", response.body
  end

  test "scanner database and archive variants are suspicious" do
    [
      "/archives.tar.xz",
      "/archives.sql.gz",
      "/application.zst",
      "/frontend.zip"
    ].each do |path|
      get path

      assert_response :not_found
      assert_equal "text/plain; charset=utf-8", response.content_type
      assert_equal "Not found\n", response.body
    end
  end

  test "repeat scanner probes are rate limited only on suspicious paths" do
    app = BotProbeFilter.new(->(_env) { [ 200, { "Content-Type" => "text/plain" }, [ "ok" ] ] })
    request = Rack::MockRequest.new(app)

    8.times do
      response = request.get("/build.tar.gz", "REMOTE_ADDR" => "203.0.113.10")
      assert_equal 404, response.status
    end

    response = request.get("/build.zip", "REMOTE_ADDR" => "203.0.113.10")
    assert_equal 429, response.status
    assert_equal "300", response["Retry-After"]

    response = request.get("/", "REMOTE_ADDR" => "203.0.113.10")
    assert_equal 200, response.status
    assert_equal "ok", response.body
  end

  test "normal missing routes still use the application error path" do
    get "/definitely-not-a-real-page"

    assert_response :not_found
    assert_includes response.body, "<html"
  end
end
