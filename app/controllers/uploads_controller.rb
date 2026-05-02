class UploadsController < ApplicationController
  before_action :require_owner!

  def show
    @failed_drive_archive_count = current_user.photos.joins(:drive_archive_object).where(drive_archive_objects: { status: "failed" }).count
  end

  private

  def require_owner!
    return if current_user&.owner?

    redirect_to root_path, alert: "Only the owner can upload photos."
  end
end
