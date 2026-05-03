class GoogleTakeoutImportJob < ApplicationJob
  queue_as :import

  def perform(import_run)
    import_run.update!(status: "running", started_at: Time.current, error: nil)
    summary = GoogleTakeoutImporter.new(owner: import_run.owner).import_path(import_run.path)
    import_run.update!(status: "succeeded", summary: summary, finished_at: Time.current)
  rescue StandardError => e
    import_run.update!(status: "failed", error: "#{e.class}: #{e.message}", finished_at: Time.current)
    raise
  end
end
