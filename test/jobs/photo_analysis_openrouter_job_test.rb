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

  test "does not pay to analyze the same derivative twice" do
    photo = attached_photo
    client = FakeVisionClient.new(response)

    perform_with_client(photo, client)
    assert_no_difference "PhotoAnalysisRun.count" do
      perform_with_client(photo, client)
    end

    assert_equal 1, client.calls
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

    assert_no_difference "PhotoAnalysisRun.count" do
      perform_with_client(photo, FakeVisionClient.new(response))
    end

    assert_equal "complete", run.reload.status
    assert run.source_checksum_sha256.present?
  end

  test "does nothing when disabled" do
    AppSetting.set_boolean!(AppSetting::ANALYSIS_OPENROUTER_ENABLED, false)

    assert_no_difference "PhotoAnalysisRun.count" do
      perform_with_client(attached_photo, FakeVisionClient.new(response))
    end
  end

  private

  FakeVisionClient = Struct.new(:response, :calls) do
    def initialize(response)
      super(response, 0)
    end

    def analyze(image_bytes:, content_type:)
      self.calls += 1
      raise "missing image bytes" if image_bytes.blank?
      raise "unexpected content type" unless content_type == "image/jpeg"

      response
    end
  end

  def perform_with_client(photo, client)
    job = PhotoAnalysisOpenrouterJob.new
    job.define_singleton_method(:vision_client) { client }
    job.perform(photo)
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
