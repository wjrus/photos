class UploadsController < ApplicationController
  owner_access_message "Only the owner can upload photos."

  before_action :require_owner!

  def show
    @failed_drive_archive_count = current_user.photos.joins(:drive_archive_object).where(drive_archive_objects: { status: "failed" }).count
  end
end
