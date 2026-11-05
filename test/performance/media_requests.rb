# Run with: PARALLEL_WORKERS=1 rbenv exec bundle exec ruby test/performance/media_requests.rb
# Synthetic test photos only. No production access or external requests.
ENV["RAILS_ENV"] ||= "test"
abort "Use the test environment for this benchmark" unless ENV["RAILS_ENV"] == "test"
require_relative "../test_helper"

class MediaRequestsBenchmarkTest < ActionDispatch::IntegrationTest
  test "report prepared media requests and revalidation" do
    owner = users(:one)
    owner.update!(password: "synthetic-benchmark-password")
    post sign_in_path, params: { email: owner.email, password: "synthetic-benchmark-password" }
    photo = owner.photos.create!(title: "Synthetic media benchmark", original: {
      io: File.open(Rails.root.join("public/icon.png")), filename: "synthetic.png", content_type: "image/png"
    })

    %i[stream display].each do |name|
      photo.original.variant(name).processed
      path = public_send("#{name}_photo_path", photo)
      get path # Warm autoloading, schema caches, and access tracking.
      assert_response :success
      etag = response.headers.fetch("ETag")
      report("#{name} bytes", :ok) { get path }
      report("#{name} revalidation", :not_modified) { get path, headers: { "If-None-Match" => etag } }
    end
    report("original bytes", :ok) { get media_photo_path(photo) }
  end

  private

  def report(label, status)
    queries = downloads = 0
    subscriber = ->(event) { queries += 1 if event.payload[:name] != "SCHEMA" && !event.payload[:cached] && event.payload[:sql].start_with?("SELECT") }
    download = ->(_event) { downloads += 1 }
    ActiveRecord::Base.clear_query_caches_for_current_thread
    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    ActiveRecord::Base.uncached do
      ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") do
        ActiveSupport::Notifications.subscribed(download, "service_download.active_storage") { yield }
      end
    end
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
    assert_response status
    puts "#{label}: #{queries} SELECTs, #{downloads} blob downloads, #{(elapsed * 1000).round(2)} ms"
  end
end
