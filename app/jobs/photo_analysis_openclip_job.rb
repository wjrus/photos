class PhotoAnalysisOpenclipJob < ApplicationJob
  queue_as :analysis

  def perform(photo)
    return unless AppSetting.boolean(AppSetting::ANALYSIS_OPENCLIP_ENABLED, default: false)

    run = photo.analysis_runs.create!(
      provider: "openclip",
      model: "pending",
      status: "running",
      started_at: Time.current,
      raw: { implementation: "pending" }
    )
    run.update!(status: "skipped", finished_at: Time.current, error: "OpenCLIP processor is not implemented yet.")
  end
end
