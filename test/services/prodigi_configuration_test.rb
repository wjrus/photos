require "test_helper"
require_relative "../support/prodigi_test_helper"

class ProdigiConfigurationTest < ActiveSupport::TestCase
  include ProdigiTestHelper
  setup { configure_prodigi }
  teardown { restore_prodigi }

  test "all supported book sizes have exact layflat catalogue defaults without SKU settings" do
    ENV.delete("PRODIGI_SKU_LANDSCAPE_A4")
    ENV.delete("PRODIGI_SKU_SQUARE_210")
    ENV.delete("PRODIGI_SKU_SQUARE_297")
    assert_equal "BOOK-FE-A4-L-LF-G", ProdigiConfiguration.sku("landscape_a4")
    assert_equal "BOOK-FE-8_3-SQ-LF-G", ProdigiConfiguration.sku("square_210")
    assert_equal "BOOK-FE-11_7-SQ-LF-G", ProdigiConfiguration.sku("square_297")
    assert_equal PhotoBook::FORMATS.keys.sort, ProdigiConfiguration::DEFAULT_SKUS.keys.sort
  end

  test "configured SKU overrides take precedence while blank settings use defaults" do
    assert_equal CONFIGURATION.fetch("PRODIGI_SKU_SQUARE_210"), ProdigiConfiguration.sku("square_210")
    ENV["PRODIGI_SKU_SQUARE_210"] = ""
    assert_equal "BOOK-FE-8_3-SQ-LF-G", ProdigiConfiguration.sku("square_210")
    assert_raises(ProdigiClient::Error) { ProdigiConfiguration.sku("unsupported") }
  end

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
