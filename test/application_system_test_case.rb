require "test_helper"

class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  SCREEN_SIZE = [ 1400, 1400 ].freeze

  # Capybara 3.40 uses a wildcard storage origin that Chrome 158 rejects.
  # A fresh browser session clears cookies and storage for every origin.
  # https://github.com/teamcapybara/capybara/issues/2865
  module ChromeStorageReset
    def reset!
      super
    rescue Selenium::WebDriver::Error::InvalidArgumentError => error
      raise unless error.message.lines.first&.strip == "invalid argument: * is not a valid URL"

      quit
    end
  end

  Capybara::Selenium::Driver::ChromeDriver.prepend(ChromeStorageReset)

  # Keep browser timing checks consistent as the suite grows past Rails' threshold.
  parallelize(workers: 1)

  driven_by :selenium, using: :headless_chrome, screen_size: SCREEN_SIZE do |options|
    options.add_argument("--window-size=#{SCREEN_SIZE.join(',')}")
  end
end
