class PhotoAnalysisYoloJob < ApplicationJob
  queue_as :analysis

  def perform(photo)
    return unless AppSetting.boolean(AppSetting::ANALYSIS_YOLO_ENABLED, default: false)

    run = photo.analysis_runs.create!(
      provider: "yolo",
      model: "pending",
      status: "running",
      started_at: Time.current,
      raw: { implementation: "pending" }
    )
    run.update!(status: "skipped", finished_at: Time.current, error: "YOLO processor is not implemented yet.")
  end
end
