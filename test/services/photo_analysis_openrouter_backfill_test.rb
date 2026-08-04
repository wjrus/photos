require "test_helper"

class PhotoAnalysisOpenrouterBackfillTest < ActiveJob::TestCase
  setup do
    AppSetting.set_boolean!(AppSetting::ANALYSIS_OPENROUTER_ENABLED, true)
    @previous_api_key = ENV["OPENROUTER_API_KEY"]
    @previous_budget = ENV["OPENROUTER_BUDGET_USD"]
    @previous_estimate = ENV["OPENROUTER_ESTIMATED_COST_USD"]
    ENV["OPENROUTER_API_KEY"] = "test-key"
    ENV["OPENROUTER_BUDGET_USD"] = "100"
    ENV["OPENROUTER_ESTIMATED_COST_USD"] = "0.01"
  end

  teardown do
    AppSetting.where(key: AppSetting::ANALYSIS_OPENROUTER_ENABLED).delete_all
    ENV["OPENROUTER_API_KEY"] = @previous_api_key
    ENV["OPENROUTER_BUDGET_USD"] = @previous_budget
    ENV["OPENROUTER_ESTIMATED_COST_USD"] = @previous_estimate
  end

  test "reserves and queues a bounded batch without duplicating it" do
    first = attached_photo("first.jpg")
    second = attached_photo("second.jpg")
    clear_enqueued_jobs

    result = nil
    assert_enqueued_jobs 1, only: PhotoAnalysisOpenrouterJob do
      result = PhotoAnalysisOpenrouterBackfill.new.enqueue(limit: 1)
    end

    assert_equal 2, result.eligible
    assert_equal 1, result.queued
    assert_equal 1, PhotoAnalysisRun.where(provider: "openrouter", status: "pending").count

    assert_enqueued_jobs 1, only: PhotoAnalysisOpenrouterJob do
      PhotoAnalysisOpenrouterBackfill.new.enqueue(limit: 10)
    end
    assert_equal 2, PhotoAnalysisRun.where(provider: "openrouter", status: "pending").count
    assert_equal [ first.id, second.id ].sort, PhotoAnalysisRun.where(provider: "openrouter").pluck(:photo_id).sort
  end

  test "dry run reports work without creating reservations" do
    attached_photo("dry-run.jpg")
    clear_enqueued_jobs

    result = nil
    assert_no_enqueued_jobs only: PhotoAnalysisOpenrouterJob do
      result = PhotoAnalysisOpenrouterBackfill.new.enqueue(limit: 100, dry_run: true)
    end

    assert_equal true, result.dry_run
    assert_equal 1, result.queued
    assert_equal 0, PhotoAnalysisRun.where(provider: "openrouter").count
  end

  test "stops reservations at the configured budget estimate" do
    3.times { |index| attached_photo("budget-#{index}.jpg") }
    ENV["OPENROUTER_BUDGET_USD"] = "0.015"
    clear_enqueued_jobs

    result = nil
    assert_enqueued_jobs 1, only: PhotoAnalysisOpenrouterJob do
      result = PhotoAnalysisOpenrouterBackfill.new.enqueue(limit: 3)
    end

    assert_equal 1, result.queued
  end

  test "counts pending reservations against the queue-time budget" do
    first = attached_photo("reserved.jpg")
    attached_photo("unreserved.jpg")
    first.analysis_runs.create!(
      provider: "openrouter",
      model: OpenrouterVisionClient::DEFAULT_MODEL,
      model_version: PhotoAnalysisOpenrouterJob::PROMPT_VERSION,
      status: "pending",
      source_variant: "display",
      raw: { queued_by: "test" }
    )
    ENV["OPENROUTER_BUDGET_USD"] = "0.015"
    clear_enqueued_jobs

    result = nil
    assert_no_enqueued_jobs only: PhotoAnalysisOpenrouterJob do
      result = PhotoAnalysisOpenrouterBackfill.new.enqueue(limit: 10)
    end

    assert_equal 0, result.queued
  end

  private

  def attached_photo(filename)
    photo = users(:one).photos.new(title: filename)
    photo.original.attach(
      io: File.open(Rails.root.join("public/icon.png"), "rb"),
      filename: filename,
      content_type: "image/jpeg"
    )
    photo.save!
    photo
  end
end
