require "test_helper"

class PhotoAnalysisYoloJobTest < ActiveJob::TestCase
  test "records skipped run while processor implementation is pending" do
    AppSetting.set_boolean!(AppSetting::ANALYSIS_YOLO_ENABLED, true)
    photo = attached_photo

    assert_difference "PhotoAnalysisRun.count", 1 do
      PhotoAnalysisYoloJob.perform_now(photo)
    end

    run = photo.analysis_runs.sole
    assert_equal "yolo", run.provider
    assert_equal "skipped", run.status
    assert_includes run.error, "not implemented"
  end

  test "does nothing when disabled" do
    AppSetting.set_boolean!(AppSetting::ANALYSIS_YOLO_ENABLED, false)

    assert_no_difference "PhotoAnalysisRun.count" do
      PhotoAnalysisYoloJob.perform_now(attached_photo)
    end
  end

  private

  def attached_photo
    photo = users(:one).photos.new(title: "YOLO candidate")
    photo.original.attach(
      io: File.open(Rails.root.join("public/icon.png"), "rb"),
      filename: "yolo-candidate.png",
      content_type: "image/png"
    )
    photo.save!
    photo
  end
end
