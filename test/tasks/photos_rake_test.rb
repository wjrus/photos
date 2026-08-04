require "test_helper"
require "rake"

class PhotosRakeTest < ActiveJob::TestCase
  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("photos:qwen")
    @task = Rake::Task["photos:qwen"]
    @task.reenable
    @previous_api_key = ENV["OPENROUTER_API_KEY"]
    ENV["OPENROUTER_API_KEY"] = "test-key"
    AppSetting.set_boolean!(AppSetting::ANALYSIS_OPENROUTER_ENABLED, true)
  end

  teardown do
    @task.reenable
    ENV["OPENROUTER_API_KEY"] = @previous_api_key
    AppSetting.where(key: AppSetting::ANALYSIS_OPENROUTER_ENABLED).delete_all
  end

  test "queues forced Qwen analysis for one photo ID" do
    photo = attached_photo

    output, = capture_io do
      assert_enqueued_with(job: PhotoAnalysisOpenrouterJob, args: [ photo, { force: true } ]) do
        @task.invoke(photo.id.to_s)
      end
    end

    assert_includes output, "Queued Qwen caption regeneration for photo #{photo.id}"
    assert_includes output, "vision queue"
  end

  private

  def attached_photo
    photo = users(:one).photos.new(title: "Single Qwen candidate")
    photo.original.attach(
      io: File.open(Rails.root.join("public/icon.png"), "rb"),
      filename: "qwen-candidate.png",
      content_type: "image/png"
    )
    photo.save!
    photo
  end
end
