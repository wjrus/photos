require "test_helper"
require_relative "../support/prodigi_test_helper"

class ProdigiConfigurationTest < ActiveSupport::TestCase
  include ProdigiTestHelper
  setup { configure_prodigi }
  teardown { restore_prodigi }

  test "public artwork and webhook URLs default to HTTPS on the configured Photos host" do
    ENV.delete("PRODIGI_PUBLIC_BASE_URL")
    assert_equal "https://photos.example.invalid", ProdigiConfiguration.public_base_url
    assert_equal "https://photos.example.invalid/webhooks/prodigi/sandbox?token=#{CONFIGURATION.fetch('PRODIGI_WEBHOOK_SECRET')}", ProdigiConfiguration.webhook_url
    ENV["PRODIGI_PUBLIC_BASE_URL"] = ""
    assert_equal "https://photos.example.invalid", ProdigiConfiguration.public_base_url
  end

  test "an explicit HTTPS origin overrides the configured host" do
    ENV["PRODIGI_PUBLIC_BASE_URL"] = "https://tunnel.example.invalid/"
    assert_equal "https://tunnel.example.invalid", ProdigiConfiguration.public_base_url
    ENV.delete("PHOTOS_HOST")
    assert_equal "https://tunnel.example.invalid", ProdigiConfiguration.public_base_url
  end

  test "missing or malformed public hosts cannot generate artwork URLs" do
    ENV.delete("PRODIGI_PUBLIC_BASE_URL")
    ENV.delete("PHOTOS_HOST")
    assert_raises(ProdigiClient::Error) { ProdigiConfiguration.public_base_url }
    [ "", "https://photos.example.invalid", "photos.example.invalid/private", "photos.example.invalid?token=example", "photos.example.invalid#fragment", "user@photos.example.invalid", "invalid host" ].each do |host|
      ENV["PHOTOS_HOST"] = host
      assert_raises(ProdigiClient::Error) { ProdigiConfiguration.public_base_url }
    end
  end

  test "explicit overrides still require a clean HTTPS origin" do
    [ "http://photos.example.invalid", "https://user@photos.example.invalid", "https://photos.example.invalid/private", "https://photos.example.invalid?token=example", "https://photos.example.invalid#fragment", "invalid url" ].each do |origin|
      ENV["PRODIGI_PUBLIC_BASE_URL"] = origin
      assert_raises(ProdigiClient::Error) { ProdigiConfiguration.public_base_url }
    end
  end
end
