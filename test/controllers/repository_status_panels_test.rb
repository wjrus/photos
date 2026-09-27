require "test_helper"

class RepositoryStatusPanelsTest < ActionDispatch::IntegrationTest
  setup do
    @owner = users(:one)
    @owner.update!(password: "synthetic-password")
    post sign_in_path, params: { email: @owner.email, password: "synthetic-password" }
    @original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
  end

  teardown do
    Rails.cache = @original_cache
  end

  test "all section shells avoid dashboard aggregates" do
    RepositoryStatusController::SECTION_PANELS.each do |section, panels|
      queries = capture_queries { get repository_status_path(section: section) }

      assert_response :success
      assert_select "[data-controller=repository-panel]", count: panels.size
      assert_empty queries.grep(/(?:file_health_checks|photo_analysis_runs|photo_embeddings|active_storage_blobs|solid_queue_|photo_metadata|drive_archive_objects)/i), section
      assert_operator queries.size, :<=, 4, "#{section}: #{queries.join('\n')}"
      assert_includes response.headers["Cache-Control"], "no-store"
      assert_select "meta[name=turbo-cache-control][content=no-cache]"
    end
  end

  test "JSON loads only the requested domain and reuses its data until expiry" do
    queries = capture_queries { get repository_status_panel_path(panel: "activity") }
    assert_response :success
    assert_equal "application/json", response.media_type
    payload = response.parsed_body
    assert_equal 60, payload.fetch("refresh_after")
    assert payload.fetch("html").present?
    assert Time.iso8601(payload.fetch("generated_at"))
    assert_empty queries.grep(/(?:photos|photo_analysis_runs|file_health_checks|solid_queue_|active_storage_)/i)

    queries = capture_queries { get repository_status_panel_path(panel: "activity") }
    assert_response :success
    assert_equal payload.fetch("version"), response.parsed_body.fetch("version")
    assert_empty queries.grep(/repository_events/i)
    assert_includes response.headers["Cache-Control"], "no-store"
  end

  test "panels use separate schedules and valid JSON envelopes" do
    RepositoryStatusData::INTERVALS.each do |panel, interval|
      get repository_status_panel_path(panel: panel)
      assert_response :success
      assert_equal interval, response.parsed_body.fetch("refresh_after"), panel
      assert response.parsed_body.fetch("html").present?, panel
    end
  end

  test "mark read expires only activity and manual refresh sees newly arrived events" do
    event = RepositoryEvent.record!(category: "file_health", event_type: "missing", severity: "warning", message: "Synthetic missing file")
    get repository_status_panel_path(panel: "activity")
    first_version = response.parsed_body.fetch("version")
    Rails.cache.write(RepositoryStatusData.cache_key(@owner.id, "library"), { sentinel: true })

    patch repository_status_path, params: { control: "repository_events" }
    assert event.reload.read?
    assert_equal({ sentinel: true }, Rails.cache.read(RepositoryStatusData.cache_key(@owner.id, "library")))
    get repository_status_panel_path(panel: "activity")
    refute_equal first_version, response.parsed_body.fetch("version")
    previous_version = response.parsed_body.fetch("version")
    RepositoryEvent.record!(category: "file_health", event_type: "missing", severity: "warning", message: "Another synthetic file")
    get repository_status_panel_path(panel: "activity", refresh: 1)
    refute_equal previous_version, response.parsed_body.fetch("version")
  end

  test "cached panels still require current owner authorization" do
    get repository_status_panel_path(panel: "library")
    assert_response :success
    delete sign_out_path
    get repository_status_panel_path(panel: "library")
    assert_response :forbidden
    refute response.parsed_body.key?("html")

    viewer = users(:two)
    viewer.update!(password: "synthetic-password")
    post sign_in_path, params: { email: viewer.email, password: "synthetic-password" }
    get repository_status_panel_path(panel: "library")
    assert_response :forbidden
    refute response.parsed_body.key?("html")
  end

  test "unknown panel and partial names cannot select arbitrary templates" do
    get repository_status_panel_path(panel: "unknown")
    assert_response :not_found
    get repository_status_panel_path(panel: "activity", variant: "../../photos/card")
    assert_response :success
    refute_includes response.parsed_body.fetch("html"), "data-photo-id"
  end

  test "event content remains escaped in the HTML inside JSON" do
    RepositoryEvent.record!(category: "file_health", event_type: "missing", severity: "warning", message: "<script>alert('synthetic')</script>")
    get repository_status_panel_path(panel: "activity")
    assert_response :success
    refute_includes response.parsed_body.fetch("html"), "<script>"
    assert_includes response.parsed_body.fetch("html"), "&lt;script&gt;"
  end

  test "queue panel preserves every execution state and diagnostic control" do
    counts = { ready: 3, claimed: 2, scheduled: 4, failed: 1, blocked: 1 }
    data = {
      snapshot_available: true, queue_totals: counts, finished_counts: { last_hour: 8, last_day: 80 },
      controls: { queues: [
        { name: "maintenance", paused: true, managed: true, counts: counts, total: 11 },
        { name: "synthetic_custom", paused: false, managed: false, counts: counts, total: 11 }
      ] },
      pauses: [ { "queue_name" => "maintenance" } ],
      job_classes: [ { name: "OriginalFileHealthCheckJob", counts: counts, total: 11 } ],
      recent_failures: [ { "class_name" => "SyntheticJob", "queue_name" => "maintenance", "error" => "Synthetic failure", "failed_at" => Time.current } ],
      pruned_failure_count: 1,
      processes: [ { "name" => "synthetic-worker", "kind" => "Worker", "pid" => 123, "hostname" => "worker.example.test", "last_heartbeat_at" => Time.current } ]
    }
    Rails.cache.write(RepositoryStatusData.cache_key(@owner.id, "queues"), { data: data, generated_at: Time.current })

    get repository_status_panel_path(panel: "queues")

    assert_response :success
    fragment = Nokogiri::HTML.fragment(response.parsed_body.fetch("html"))
    %w[Ready Running Scheduled Failed Blocked].each { |label| assert_includes fragment.text, label }
    assert_equal [ "maintenance" ], fragment.css("input[name=queue_name]").map { |input| input["value"] }
    [ queue_pauses_path, retry_pruned_queue_failures_path, queue_failures_path ].each do |action|
      assert_equal 1, fragment.css("form[action='#{action}']").size
    end
    assert_equal 1, fragment.css("[role=dialog][aria-modal=true]").size
    assert_includes fragment.text, "worker.example.test"
    assert_includes fragment.text, "OriginalFileHealthCheckJob"
  end

  private

  def capture_queries
    queries = []
    subscriber = ->(event) { queries << event.payload[:sql] unless event.payload[:name] == "SCHEMA" || event.payload[:cached] }
    ActiveRecord::Base.uncached do
      ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") { yield }
    end
    queries
  end
end
