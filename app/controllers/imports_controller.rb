class ImportsController < ApplicationController
  before_action :require_owner!

  def index
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

  private

  def require_owner!
    return if current_user&.owner?

    redirect_to root_path, alert: "Only the owner can see imports."
  end
end
