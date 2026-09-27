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

    def assign_photo_place(photo, name: nil, place: nil, identity_key: nil, names: [], raw: {}, place_type: "locality")
      metadata = photo.metadata
      place ||= PhotoPlace.create!(
        identity_key: identity_key || "test:#{SecureRandom.uuid}", name: name, names: names, raw: raw,
        latitude: metadata.latitude, longitude: metadata.longitude, place_type: place_type
      )
      metadata.update!(photo_place: place, location_source: "automatic")
      place
    end

    # Add more helper methods to be used by all tests here...
  end
end
