require "test_helper"

class MailgunClientTest < ActiveSupport::TestCase
  setup do
    @previous_env = ENV.to_h.slice(
      "MAILGUN_API_KEY",
      "MAILGUN_DOMAIN",
      "MAILGUN_FROM",
      "MAILER_SENDER",
      "MAILGUN_FROM_NAME",
      "MAILER_SENDER_NAME",
      "MAILGUN_REPLY_TO",
      "MAILGUN_API_BASE",
      "MAILGUN_API_BASE_URL"
    )
  end

  teardown do
    @previous_env.each { |key, value| ENV[key] = value }
    (tracked_env_keys - @previous_env.keys).each { |key| ENV.delete(key) }
  end

  test "uses mailer sender alias instead of falling back to an example address" do
    ENV.delete("MAILGUN_FROM")
    ENV["MAILER_SENDER"] = "sender@example.invalid"
    ENV["MAILGUN_FROM_NAME"] = "Shared Photos"

    assert_equal "\"Shared Photos\" <sender@example.invalid>", MailgunClient.default_from
  end

  test "requires an explicit sender address" do
    ENV.delete("MAILGUN_FROM")
    ENV.delete("MAILER_SENDER")

    error = assert_raises(MailgunClient::DeliveryError) { MailgunClient.default_from }

    assert_includes error.message, "MAILGUN_FROM or MAILER_SENDER"
  end

  test "uses api base url alias" do
    ENV.delete("MAILGUN_API_BASE")
    ENV["MAILGUN_API_BASE_URL"] = "https://mailgun.example.invalid"

    assert_equal "https://mailgun.example.invalid", MailgunClient.send(:api_base)
  end

  private

  def tracked_env_keys
    @previous_env.keys + [
      "MAILGUN_API_KEY",
      "MAILGUN_DOMAIN",
      "MAILGUN_FROM",
      "MAILER_SENDER",
      "MAILGUN_FROM_NAME",
      "MAILER_SENDER_NAME",
      "MAILGUN_REPLY_TO",
      "MAILGUN_API_BASE",
      "MAILGUN_API_BASE_URL"
    ]
  end
end
