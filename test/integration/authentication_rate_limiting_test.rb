require "test_helper"

class AuthenticationRateLimitingTest < ActionDispatch::IntegrationTest
  test "password attempts are limited by IP and recover after the window" do
    with_rate_limit_cache do
      10.times do |index|
        post password_sign_in_path, params: { email: "unknown-#{index}@example.com", password: "incorrect" }
        assert_response :redirect
      end

      post password_sign_in_path, params: { email: "another@example.com", password: "incorrect" }
      assert_response :too_many_requests
      assert_equal "180", response.headers["Retry-After"]

      travel 3.minutes + 1.second do
        post password_sign_in_path, params: { email: "another@example.com", password: "incorrect" }
        assert_response :redirect
      end
    end
  end

  test "password attempts share an email limit across IPs and email casing" do
    with_rate_limit_cache do
      10.times do |index|
        post password_sign_in_path, params: { email: "unknown@example.com", password: "incorrect" },
          env: { "REMOTE_ADDR" => "203.0.113.#{index + 1}" }
        assert_response :redirect
      end

      post password_sign_in_path, params: { email: " UNKNOWN@EXAMPLE.COM ", password: "incorrect" },
        env: { "REMOTE_ADDR" => "203.0.113.20" }
      assert_response :too_many_requests
      assert_equal "900", response.headers["Retry-After"]
    end
  end

  test "reset requests limit emails across IPs without consuming another reset token" do
    with_rate_limit_cache do
      MailgunClient.clear_deliveries
      user = users(:two)
      3.times do |index|
        post password_reset_path, params: { email: user.email }, env: { "REMOTE_ADDR" => "203.0.113.#{index + 1}" }
        assert_response :redirect
      end
      token_digest = user.reload.password_reset_token_digest

      assert_no_difference "MailgunClient.deliveries.size" do
        post password_reset_path, params: { email: " #{user.email.upcase} " }, env: { "REMOTE_ADDR" => "203.0.113.20" }
      end
      assert_response :too_many_requests
      assert_equal token_digest, user.reload.password_reset_token_digest
      assert_equal "3600", response.headers["Retry-After"]
    end
  end

  test "reset requests also limit unknown accounts and attempts across different emails" do
    with_rate_limit_cache do
      3.times { post password_reset_path, params: { email: "unknown@example.com" } }
      post password_reset_path, params: { email: "unknown@example.com" }
      assert_response :too_many_requests

      post password_reset_path, params: { email: "second@example.com" }
      assert_response :redirect
      post password_reset_path, params: { email: "third@example.com" }
      assert_response :too_many_requests
      assert_equal "600", response.headers["Retry-After"]
    end
  end

  private

  def with_rate_limit_cache
    cache = ActiveSupport::Cache::MemoryStore.new
    store = ApplicationController.cache_store
    store.define_singleton_method(:increment) { |*args, **kwargs| cache.increment(*args, **kwargs) }
    yield
  ensure
    store.singleton_class.remove_method(:increment)
  end
end
