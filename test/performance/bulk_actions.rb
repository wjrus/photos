# Run with: PARALLEL_WORKERS=1 rbenv exec bundle exec ruby test/performance/bulk_actions.rb
# Synthetic photos in the test database only; fixture changes roll back.
ENV["RAILS_ENV"] ||= "test"
abort "Use the test environment for this benchmark" unless ENV["RAILS_ENV"] == "test"
require_relative "../test_helper"

class BulkActionsBenchmarkTest < ActiveSupport::TestCase
  test "report bulk publication reads and writes as selection size grows" do
    owner = users(:one)
    blob = ActiveStorage::Blob.create_and_upload!(
      io: File.open(Rails.root.join("public/icon.png")), filename: "synthetic-bulk.png", content_type: "image/png"
    )
    photos = 200.times.map { |index| owner.photos.create!(title: "Synthetic bulk #{index}", original: blob) }

    [ 1, 10, 200 ].each do |size|
      selection = photos.first(size).reverse
      Photo.where(id: selection.map(&:id)).update_all(visibility: "private", published_at: nil)
      reads = writes = 0
      subscriber = ->(event) {
        next if event.payload[:cached] || event.payload[:name] == "SCHEMA"

        reads += 1 if event.payload[:sql].start_with?("SELECT")
        writes += 1 if event.payload[:sql].start_with?("UPDATE")
      }
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = nil
      ActiveRecord::Base.uncached do
        ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") do
          result = PhotoBulkOperation.new(owner: owner, photos: selection, action: "publish", attributes: {}).call
        end
      end
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      assert_equal size, result[:affected_count]
      assert_equal size, Photo.where(id: selection.map(&:id), visibility: "public").count
      puts "#{size} photos: #{reads} SELECTs, #{writes} UPDATEs, #{(elapsed * 1000).round(2)} ms"
    end
  end
end
