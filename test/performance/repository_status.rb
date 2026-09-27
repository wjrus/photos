# Run with: rbenv exec bundle exec ruby test/performance/repository_status.rb
# Synthetic fixtures, test database, and an isolated in-memory cache only.
ENV["RAILS_ENV"] ||= "test"
abort "Use the test environment for this benchmark" unless ENV["RAILS_ENV"] == "test"
require_relative "../test_helper"

class RepositoryStatusBenchmarkTest < ActionDispatch::IntegrationTest
  test "report initial page and panel query counts" do
    owner = users(:one)
    owner.update!(password: "synthetic-benchmark-password")
    post sign_in_path, params: { email: owner.email, password: "synthetic-benchmark-password" }
    original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new

    RepositoryStatusController::SECTION_PANELS.each_key do |section|
      report("page #{section}") { get repository_status_path(section: section) }
    end
    RepositoryStatusData::INTERVALS.each_key do |panel|
      Rails.cache.clear
      report("panel #{panel} cold") { get repository_status_panel_path(panel: panel) }
      report("panel #{panel} cached") { get repository_status_panel_path(panel: panel) }
    end
  ensure
    Rails.cache = original_cache if original_cache
  end

  private

  def report(label)
    count = 0
    subscriber = ->(event) { count += 1 unless event.payload[:name] == "SCHEMA" || event.payload[:cached] }
    ActiveRecord::Base.uncached do
      ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") { yield }
    end
    assert_response :success
    puts "#{label}: #{count} SQL queries"
  end
end
