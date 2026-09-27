require "test_helper"
require "active_record/testing/query_assertions"

class RepositoryStatusDataTest < ActiveSupport::TestCase
  include ActiveRecord::Assertions::QueryAssertions

  setup do
    @previous_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    @owner = users(:one)
    @service = RepositoryStatusData.new(owner_id: @owner.id)
    @now = Time.zone.parse("2026-09-27 15:30:00")
    travel_to @now
  end

  teardown do
    travel_back
    Rails.cache = @previous_cache
  end

  test "cached library reads avoid aggregate queries across requests and refresh on demand" do
    attached_photo
    first = nil
    assert_queries_count(4) { first = @service.fetch("library") }
    assert_equal 1, first.dig(:data, :originals, :total)
    attached_photo

    assert_no_queries do
      assert_equal first, RepositoryStatusData.new(owner_id: @owner.id).fetch("library")
    end

    refreshed = @service.fetch("library", force: true)
    assert_equal 2, refreshed.dig(:data, :originals, :total)
    assert_no_queries { assert_equal refreshed, @service.fetch("library") }
  end

  test "queue activity and library panels expire independently" do
    first = %w[queues activity library].index_with { |panel| @service.fetch(panel) }

    travel 21.seconds
    assert_operator @service.fetch("queues")[:generated_at], :>, first.fetch("queues")[:generated_at]
    assert_no_queries do
      assert_equal first.fetch("activity"), @service.fetch("activity")
      assert_equal first.fetch("library"), @service.fetch("library")
    end

    travel 40.seconds
    assert_operator @service.fetch("activity")[:generated_at], :>, first.fetch("activity")[:generated_at]
    assert_no_queries { assert_equal first.fetch("library"), @service.fetch("library") }

    attached_photo
    travel 240.seconds
    assert_equal 1, @service.fetch("library").dig(:data, :originals, :total)
  end

  test "explicit invalidation targets only the requested owner and panels" do
    attached_photo
    other_owner_service = RepositoryStatusData.new(owner_id: users(:two).id)
    first = @service.fetch("library")
    activity = @service.fetch("activity")
    other_owner_service.fetch("library")
    attached_photo

    RepositoryStatusData.invalidate(@owner.id, :library)

    assert_equal 2, @service.fetch("library").dig(:data, :originals, :total)
    assert_no_queries do
      assert_equal activity, @service.fetch("activity")
      assert_equal first, other_owner_service.fetch("library")
    end
  end

  test "forcing maintenance also refreshes its cached library totals" do
    attached_photo
    assert_equal 1, @service.fetch("maintenance").dig(:data, :originals, :total)
    attached_photo

    maintenance = @service.fetch("maintenance", force: true)

    assert_equal 2, maintenance.dig(:data, :originals, :total)
    assert_equal 2, maintenance.dig(:data, :derivatives, :image_total)
    assert_no_queries { assert_equal 2, @service.fetch("library").dig(:data, :originals, :total) }
  end

  test "forcing health also refreshes cached health job counts from queues" do
    cached_queue_data = {
      job_classes: [ { name: "OriginalFileHealthCheckJob", total: 5,
        counts: { ready: 5, claimed: 0, scheduled: 0, failed: 0, blocked: 0 } },
        { name: "PhotoAnalysisJob", total: 99, counts: { ready: 99, claimed: 0, scheduled: 0, failed: 0, blocked: 0 } } ]
    }
    Rails.cache.write(RepositoryStatusData.cache_key(@owner.id, "queues"), { data: cached_queue_data, generated_at: @now }, expires_in: 20.seconds)
    assert_equal 5, @service.fetch("health").dig(:data, :health, :jobs, :total)

    health = @service.fetch("health", force: true).dig(:data, :health)
    assert_equal 0, health.dig(:jobs, :total)
    assert_equal 100.0, health.fetch(:checked_percent)
  end

  test "library counts preserve visibility restricted archived and media categories" do
    public_photo = attached_photo(visibility: "public", bytes: 100)
    private_photo = attached_photo(bytes: 200, checksum_status: "pending")
    attached_photo(content_type: "video/mp4", bytes: 300, checksum_status: "failed")
    attached_photo(restricted: true, bytes: 400)
    attached_photo(visibility: "public", archived_at: 1.day.ago, bytes: 500)
    attached_photo(content_type: "video/mp4", restricted: true, archived_at: 1.day.ago, bytes: 600)
    detached_photo = attached_photo(bytes: 700)
    detached_photo.original_attachment.delete
    DriveArchiveObject.create!(photo: public_photo, status: "archived")
    DriveArchiveObject.create!(photo: private_photo, status: "failed")

    library = @service.fetch("library").fetch(:data)

    assert_equal({ total: 6, images: 4, videos: 2, public: 1, private: 2, restricted: 2, archived: 2, bytes: 2_100 }, library.fetch(:originals))
    assert_equal({ "complete" => 5, "pending" => 1, "failed" => 1 }, library.fetch(:checksums))
    assert_equal({ "archived" => 1, "failed" => 1 }, library.fetch(:drive_archives))
  end

  test "health uses only the newest check for attached originals with deterministic ties" do
    recovered = attached_photo
    record_check(recovered, status: "missing", checked_at: 2.hours.ago)
    recovered_check = record_check(recovered, status: "ok", checked_at: 1.hour.ago)
    tied = attached_photo
    record_check(tied, status: "missing", checked_at: 30.minutes.ago)
    tied_check = record_check(tied, status: "healed", checked_at: 30.minutes.ago)
    stale = attached_photo
    stale_check = record_check(stale, status: "error", checked_at: 2.days.ago)
    detached = attached_photo
    record_check(detached, status: "missing", checked_at: 1.minute.ago)
    detached.original_attachment.delete
    attached_photo

    data = @service.fetch("health").fetch(:data)
    health = data.fetch(:health)

    assert_equal 3, health.fetch(:checked)
    assert_equal 1, health.fetch(:unchecked)
    assert_equal 75.0, health.fetch(:checked_percent)
    assert_equal 1, health.fetch(:attention)
    assert_equal 1, health.fetch(:stale)
    assert_equal({ "ok" => 1, "healed" => 1, "error" => 1 }, health.fetch(:status_counts))
    assert_equal [ tied_check, recovered_check, stale_check ], data.fetch(:recent_checks).pluck("id")
    assert_equal [ stale_check ], data.fetch(:recent_attention).pluck("id")
  end

  test "health timeline groups check history in SQL and bounds its time window" do
    photo = attached_photo
    120.times { record_check(photo, status: "ok", checked_at: @now - 2.hours) }
    3.times { record_check(photo, status: "healed", checked_at: @now - 2.hours) }
    2.times { record_check(photo, status: "missing", checked_at: @now - 2.hours) }
    record_check(photo, status: "ok", checked_at: @now - 25.hours)
    record_check(photo, status: "error", checked_at: @now + 1.hour)

    data = nil
    queries = capture_queries { data = @service.fetch("health").fetch(:data) }
    timeline = data.fetch(:health_timeline)

    assert_equal 25, timeline.size
    assert_equal 123, timeline.sum { |bucket| bucket.fetch(:healthy) }
    assert_equal 2, timeline.sum { |bucket| bucket.fetch(:attention) }
    assert_equal 123, timeline.find { |bucket| bucket.fetch(:label) == (@now - 2.hours).strftime("%-I%P") }.fetch(:healthy)
    assert_equal 1, queries.count { |sql| sql.include?("EXTRACT(EPOCH FROM checked_at)") && sql.include?("GROUP BY") }
    assert queries.none? { |sql| sql.match?(/SELECT\s+"file_health_checks"\."checked_at",\s*"file_health_checks"\."status"/) }, queries.join("\n")
  end

  test "analysis groups runs for current models and measures coverage only for eligible originals" do
    image = attached_photo
    other_image = attached_photo
    video = attached_photo(content_type: "video/mp4")
    archived = attached_photo(archived_at: 1.day.ago)
    restricted = attached_photo(restricted: true)
    detached = attached_photo
    detached.original_attachment.delete
    clip_model = ENV.fetch("OPENCLIP_MODEL", "ViT-B-32")
    clip_version = ENV.fetch("OPENCLIP_PRETRAINED", "laion2b_s34b_b79k")
    router_model = ENV.fetch("OPENROUTER_VISION_MODEL", OpenrouterVisionClient::DEFAULT_MODEL)
    router_version = PhotoAnalysisOpenrouterJob::PROMPT_VERSION
    [ image, restricted, detached ].each { |photo| add_embedding(photo, model: clip_model, version: clip_version) }
    add_embedding(other_image, model: "synthetic-obsolete-model", version: clip_version)
    add_run(image, provider: "openclip", model: clip_model, version: clip_version, status: "complete")
    add_run(other_image, provider: "openclip", model: clip_model, version: clip_version, status: "running")
    add_run(other_image, provider: "openclip", model: clip_model, version: "obsolete", status: "failed")
    2.times { add_run(image, provider: "openrouter", model: router_model, version: router_version, status: "complete") }
    [ video, restricted, detached ].each do |photo|
      add_run(photo, provider: "openrouter", model: router_model, version: router_version, status: "complete")
    end
    add_run(other_image, provider: "openrouter", model: router_model, version: router_version, status: "pending")
    add_run(archived, provider: "openrouter", model: "synthetic-obsolete-model", version: router_version, status: "complete")

    result = nil
    queries = capture_queries { result = @service.fetch("analysis").dig(:data, :analysis_status) }
    clip = result.fetch(:openclip)
    router = result.fetch(:openrouter)

    assert_equal 4, clip.fetch(:eligible)
    assert_equal 1, clip.fetch(:embedded)
    assert_equal 3, clip.fetch(:missing)
    assert_equal 25.0, clip.fetch(:coverage_percent)
    assert_equal({ "pending" => 0, "running" => 1, "complete" => 1, "failed" => 0, "skipped" => 0 }, clip.fetch(:run_counts))
    assert_equal 3, router.fetch(:eligible)
    assert_equal 1, router.fetch(:completed)
    assert_equal 2, router.fetch(:missing)
    assert_equal 33.3, router.fetch(:coverage_percent)
    assert_equal({ "pending" => 1, "running" => 0, "complete" => 5, "failed" => 0, "skipped" => 0 }, router.fetch(:run_counts))
    assert_equal 2, queries.count { |sql| sql.include?("GROUP BY \"photo_analysis_runs\".\"status\"") }
  end

  private

  def attached_photo(content_type: "image/png", bytes: 100, **attributes)
    id = Photo.insert_all!([ {
      owner_id: @owner.id, original_filename: "synthetic-original.png", content_type: content_type,
      checksum_status: "complete", created_at: @now, updated_at: @now
    }.merge(attributes) ]).rows.first.first
    blob = ActiveStorage::Blob.create!(
      key: SecureRandom.hex, filename: "synthetic-original.png", content_type: content_type,
      byte_size: bytes, checksum: "synthetic-checksum", service_name: "test", metadata: { analyzed: true, identified: true }
    )
    ActiveStorage::Attachment.insert_all!([ { name: "original", record_type: "Photo", record_id: id, blob_id: blob.id, created_at: @now } ])
    Photo.find(id)
  end

  def record_check(photo, status:, checked_at:)
    FileHealthCheck.insert_all!([ {
      photo_id: photo.id, active_storage_blob_id: photo.original.blob.id, blob_key: photo.original.blob.key,
      status: status, checked_at: checked_at, created_at: @now, updated_at: @now
    } ]).rows.first.first
  end

  def add_embedding(photo, model:, version:)
    PhotoEmbedding.create!(photo: photo, provider: "openclip", model: model, model_version: version,
      index_key: "synthetic-#{SecureRandom.hex}", dimensions: 512, embedded_at: @now, raw: { synthetic: true })
  end

  def add_run(photo, provider:, model:, version:, status:)
    PhotoAnalysisRun.create!(photo: photo, provider: provider, model: model, model_version: version, status: status, raw: { synthetic: true })
  end

  def capture_queries
    queries = []
    subscriber = ->(_name, _started, _finished, _unique_id, payload) do
      queries << payload[:sql] unless payload[:name] == "SCHEMA" || payload[:cached]
    end
    ActiveRecord::Base.uncached do
      ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") { yield }
    end
    queries
  end
end
