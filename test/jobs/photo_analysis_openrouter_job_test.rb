require "test_helper"

class PhotoAnalysisOpenrouterJobTest < ActiveJob::TestCase
  setup do
    AppSetting.set_boolean!(AppSetting::ANALYSIS_OPENROUTER_ENABLED, true)
  end

  teardown do
    AppSetting.where(key: [
      AppSetting::ANALYSIS_OPENROUTER_ENABLED,
      AppSetting::ANALYSIS_OPENROUTER_AUTO_NEW_ENABLED
    ]).delete_all
  end

  test "records analysis tags usage and an editable caption" do
    photo = attached_photo
    client = FakeVisionClient.new(response)

    assert_difference [ "PhotoAnalysisRun.count", "PhotoAnalysisTag.count" ], 1 do
      perform_with_client(photo, client)
    end

    run = photo.analysis_runs.where(provider: "openrouter").sole
    assert_equal "complete", run.status
    assert_equal "A black dog sits beside a window.", run.summary
    assert_equal "generation-123", run.request_id
    assert_equal 2_500, run.input_tokens
    assert_equal 18, run.output_tokens
    assert_equal 0.000386.to_d, run.cost_usd
    assert_equal "A black dog sits beside a window.", photo.reload.description
    assert_equal [ "dog" ], photo.analysis_tags.where(provider: "openrouter").pluck(:name)
    assert_equal "display", run.source_variant
    assert_equal 64, run.source_checksum_sha256.length

    photo.update!(description: "My own caption.")
    assert_equal "My own caption.", photo.reload.description
  end

  test "does not overwrite a handwritten caption" do
    photo = attached_photo(description: "My own caption.")

    perform_with_client(photo, FakeVisionClient.new(response))

    assert_equal "My own caption.", photo.reload.description
    assert_equal "A black dog sits beside a window.", photo.analysis_runs.where(provider: "openrouter").sole.summary
  end

  test "provides friendly local metadata without exact coordinates" do
    photo = attached_photo
    metadata = photo.create_metadata!(
      extraction_status: "complete",
      captured_at: Time.zone.parse("2026-08-04 14:30:00"),
      camera_make: "Apple",
      camera_model: "iPhone 17 Pro",
      latitude: 45.3733,
      longitude: -84.9553,
      raw: {}
    )
    PhotoLocationPlace.create!(
      location_id: PhotoLocation.id_for_coordinates(metadata.latitude, metadata.longitude),
      name: "Kilwins, Petoskey",
      raw: {
        "address_components" => [
          { "long_name" => "Kilwins", "types" => [ "point_of_interest" ] },
          { "long_name" => "Petoskey", "types" => [ "locality" ] },
          { "long_name" => "Michigan", "types" => [ "administrative_area_level_1" ] },
          { "long_name" => "United States", "types" => [ "country" ] }
        ]
      }
    )
    client = FakeVisionClient.new(response)

    perform_with_client(photo, client)

    context = client.contexts.sole
    assert_equal "Petoskey, Michigan, United States", context.fetch(:approximate_location)
    assert_equal "2026-08-04", context.fetch(:capture_date)
    assert_equal "Apple iPhone 17 Pro", context.fetch(:camera)
    refute_includes context.values, metadata.latitude.to_s
    assert_equal context.stringify_keys, photo.analysis_runs.where(provider: "openrouter").sole.raw.fetch("input_context")
  end

  test "does not pay to analyze the same derivative twice" do
    photo = attached_photo
    client = FakeVisionClient.new(response)

    perform_with_client(photo, client)
    assert_no_difference "PhotoAnalysisRun.count" do
      perform_with_client(photo, client)
    end

    assert_equal 1, client.calls
  end

  test "forced analysis regenerates an existing generated caption" do
    photo = attached_photo
    perform_with_client(photo, FakeVisionClient.new(response))

    regenerated = response.merge(
      "request_id" => "generation-456",
      "caption" => "A black dog rests beside a sunny window.",
      "raw" => { "id" => "generation-456" }
    )
    perform_with_client(photo, FakeVisionClient.new(regenerated), force: true)

    assert_equal 2, photo.analysis_runs.where(provider: "openrouter", status: "complete").count
    assert_equal "A black dog rests beside a sunny window.", photo.reload.description
  end

  test "forced analysis preserves a caption edited after generation" do
    photo = attached_photo
    perform_with_client(photo, FakeVisionClient.new(response))
    photo.update!(description: "My corrected caption.")

    regenerated = response.merge(
      "request_id" => "generation-456",
      "caption" => "A black dog rests beside a sunny window.",
      "raw" => { "id" => "generation-456" }
    )
    perform_with_client(photo, FakeVisionClient.new(regenerated), force: true)

    assert_equal "My corrected caption.", photo.reload.description
  end

  test "claims a pending backfill reservation" do
    photo = attached_photo
    run = photo.analysis_runs.create!(
      provider: "openrouter",
      model: OpenrouterVisionClient::DEFAULT_MODEL,
      model_version: PhotoAnalysisOpenrouterJob::PROMPT_VERSION,
      status: "pending",
      source_variant: "display",
      raw: { queued_by: "backfill" }
    )
    photo.create_metadata!(
      extraction_status: "complete",
      captured_at: Time.zone.parse("2026-08-04 14:30:00"),
      raw: {}
    )

    assert_no_difference "PhotoAnalysisRun.count" do
      perform_with_client(photo, FakeVisionClient.new(response))
    end

    assert_equal "complete", run.reload.status
    assert run.source_checksum_sha256.present?
    assert_equal "2026-08-04", run.raw.dig("input_context", "capture_date")
  end

  test "does nothing when disabled" do
    AppSetting.set_boolean!(AppSetting::ANALYSIS_OPENROUTER_ENABLED, false)

    assert_no_difference "PhotoAnalysisRun.count" do
      perform_with_client(attached_photo, FakeVisionClient.new(response))
    end
  end

  test "retries rate limits using openrouter retry after guidance" do
    photo = attached_photo
    client = FakeVisionClient.new(nil)
    client.define_singleton_method(:analyze) do |**|
      raise OpenrouterVisionClient::RetryableError.new("rate limited", retry_after: 60)
    end
    job = PhotoAnalysisOpenrouterJob.new(photo)
    job.define_singleton_method(:vision_client) { client }

    travel_to Time.zone.parse("2026-08-04 12:00:00") do
      assert_enqueued_with(job: PhotoAnalysisOpenrouterJob, at: 60.seconds.from_now) do
        job.perform_now
      end
    end
  end

  test "records failed response diagnostics and cost before retrying" do
    photo = attached_photo
    details = {
      "request_id" => "generation-empty",
      "model" => OpenrouterVisionClient::DEFAULT_MODEL,
      "provider" => "SiliconFlow",
      "finish_reason" => "stop",
      "content_bytes" => 0,
      "usage" => { "prompt_tokens" => 2_500, "completion_tokens" => 0, "cost" => 0.00075 }
    }
    client = FakeVisionClient.new(nil)
    client.define_singleton_method(:analyze) do |**|
      raise OpenrouterVisionClient::RetryableError.new("empty vision content", details:)
    end
    job = PhotoAnalysisOpenrouterJob.new(photo)
    job.define_singleton_method(:vision_client) { client }

    assert_enqueued_with(job: PhotoAnalysisOpenrouterJob) { job.perform_now }

    run = photo.analysis_runs.where(provider: "openrouter").sole
    assert_equal "failed", run.status
    assert_equal "generation-empty", run.request_id
    assert_equal 0.00075.to_d, run.cost_usd
    assert_equal "SiliconFlow", run.raw.dig("failure_response", "provider")
  end

  test "marks a failed attempt as recovered after a successful retry" do
    photo = attached_photo
    client = FakeVisionClient.new(nil)
    client.define_singleton_method(:analyze) do |**|
      raise OpenrouterVisionClient::RetryableError, "empty vision content"
    end

    assert_raises(OpenrouterVisionClient::RetryableError) { perform_with_client(photo, client) }
    failed_run = photo.analysis_runs.where(provider: "openrouter").sole

    perform_with_client(photo, FakeVisionClient.new(response))

    assert_equal "skipped", failed_run.reload.status
    assert_match(/Recovered after retry/, failed_run.error)
    assert_equal 1, photo.analysis_runs.where(provider: "openrouter", status: "complete").count
  end

  private

  FakeVisionClient = Struct.new(:response, :calls, :contexts) do
    def initialize(response)
      super(response, 0, [])
    end

    def analyze(image_bytes:, content_type:, context: {})
      self.calls += 1
      contexts << context
      raise "missing image bytes" if image_bytes.blank?
      raise "unexpected content type" unless content_type == "image/jpeg"

      response
    end
  end

  def perform_with_client(photo, client, force: false)
    job = PhotoAnalysisOpenrouterJob.new
    job.define_singleton_method(:vision_client) { client }
    job.perform(photo, force:)
  end

  def attached_photo(description: nil)
    photo = users(:one).photos.new(title: "Vision candidate", description: description)
    photo.original.attach(
      io: File.open(Rails.root.join("public/icon.png"), "rb"),
      filename: "vision-candidate.png",
      content_type: "image/png"
    )
    photo.save!
    photo.original.variant(:display).processed
    photo
  end

  def response
    {
      "request_id" => "generation-123",
      "model" => "qwen/qwen3-vl-30b-a3b-instruct",
      "provider" => "DeepInfra",
      "caption" => "A black dog sits beside a window.",
      "tags" => [ "dog" ],
      "readable_text" => [],
      "input_tokens" => 2_500,
      "output_tokens" => 18,
      "cost" => 0.000386,
      "raw" => { "id" => "generation-123" }
    }
  end
end
