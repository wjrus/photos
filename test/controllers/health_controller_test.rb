require "test_helper"

class HealthControllerTest < ActionDispatch::IntegrationTest
  test "head health probe identifies the serving backend" do
    previous = ENV["PHOTOS_WEB_BACKEND"]
    ENV["PHOTOS_WEB_BACKEND"] = "web_green"

    head rails_health_check_path

    assert_response :ok
    assert_equal "web_green", response.headers["X-Photos-Backend"]
    assert_empty response.body
  ensure
    ENV["PHOTOS_WEB_BACKEND"] = previous
  end
end
