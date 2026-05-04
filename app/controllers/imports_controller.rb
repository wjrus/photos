class ImportsController < ApplicationController
  owner_access_message "Only the owner can see imports."

  before_action :require_owner!

  def index
    @default_import_path = ENV.fetch("PHOTOS_TAKEOUT_IMPORT_PATH", "/rails/imports/google-takeout")
    @import_runs = GoogleTakeoutImportRun.includes(:owner).recent.limit(12)
    @status_counts = GoogleTakeoutImport.group(:status).count
    @totals_by_zip = GoogleTakeoutImport
      .group(:zip_path)
      .group(:status)
      .count
      .each_with_object({}) do |((zip_path, status), count), totals|
        totals[zip_path] ||= {}
        totals[zip_path][status] = count
      end
    @recent_imports = GoogleTakeoutImport.includes(:photo).order(updated_at: :desc).limit(25)
    @recent_failures = GoogleTakeoutImport.where(status: "failed").order(updated_at: :desc).limit(25)
  end

  def create
    import_path = params[:path].presence || ENV.fetch("PHOTOS_TAKEOUT_IMPORT_PATH", "/rails/imports/google-takeout")
    import_run = current_user.google_takeout_import_runs.create!(path: import_path)
    GoogleTakeoutImportJob.perform_later(import_run)

    redirect_to imports_path, notice: "Import queued."
  end
end
