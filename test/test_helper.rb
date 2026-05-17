ENV["RAILS_ENV"] ||= "test"
ENV["MAILGUN_API_KEY"] ||= "test-mailgun-key"
ENV["MAILGUN_DOMAIN"] ||= "mg.example.invalid"
ENV["MAILGUN_FROM"] ||= "photos@example.invalid"
require_relative "../config/environment"
require "rails/test_help"

module ActiveSupport
  class TestCase
    include ActiveJob::TestHelper

    # Run tests in parallel with specified workers
    parallelize(workers: :number_of_processors)

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    # Add more helper methods to be used by all tests here...
  end
end
