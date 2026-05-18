require "test_helper"

class PhotoAnalysisOpenclipJobTest < ActiveJob::TestCase
  test "records skipped run while processor implementation is pending" do
    AppSetting.set_boolean!(AppSetting::ANALYSIS_OPENCLIP_ENABLED, true)
    photo = attached_photo

    assert_difference "PhotoAnalysisRun.count", 1 do
      PhotoAnalysisOpenclipJob.perform_now(photo)
    end

    run = photo.analysis_runs.sole
    assert_equal "openclip", run.provider
    assert_equal "skipped", run.status
    assert_includes run.error, "not implemented"
  end

  test "does nothing when disabled" do
    AppSetting.set_boolean!(AppSetting::ANALYSIS_OPENCLIP_ENABLED, false)

    assert_no_difference "PhotoAnalysisRun.count" do
      PhotoAnalysisOpenclipJob.perform_now(attached_photo)
    end
  end

  private

  def attached_photo
    photo = users(:one).photos.new(title: "OpenCLIP candidate")
    photo.original.attach(
      io: File.open(Rails.root.join("public/icon.png"), "rb"),
      filename: "openclip-candidate.png",
      content_type: "image/png"
    )
    photo.save!
    photo
  end
end
