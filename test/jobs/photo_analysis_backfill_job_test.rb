require "test_helper"

class PhotoAnalysisBackfillJobTest < ActiveJob::TestCase
  setup do
    @photo = attached_photo
    clear_enqueued_jobs
  end

  test "queues enabled local analysis providers" do
    AppSetting.set_boolean!(AppSetting::ANALYSIS_OPENCLIP_ENABLED, true)
    AppSetting.set_boolean!(AppSetting::ANALYSIS_YOLO_ENABLED, true)

    PhotoAnalysisBackfillJob.perform_now

    assert_enqueued_with(job: PhotoAnalysisOpenclipJob, args: [ @photo ])
    assert_enqueued_with(job: PhotoAnalysisYoloJob, args: [ @photo ])
  end

  test "does not queue disabled providers" do
    AppSetting.set_boolean!(AppSetting::ANALYSIS_OPENCLIP_ENABLED, false)
    AppSetting.set_boolean!(AppSetting::ANALYSIS_YOLO_ENABLED, false)

    PhotoAnalysisBackfillJob.perform_now

    assert_no_enqueued_jobs only: [ PhotoAnalysisOpenclipJob, PhotoAnalysisYoloJob ]
  end

  private

  def attached_photo
    photo = users(:one).photos.new(title: "Analysis candidate")
    photo.original.attach(
      io: File.open(Rails.root.join("public/icon.png"), "rb"),
      filename: "analysis-candidate.png",
      content_type: "image/png"
    )
    photo.save!
    photo
  end
end
