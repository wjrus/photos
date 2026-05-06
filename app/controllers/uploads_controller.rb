class UploadsController < ApplicationController
  owner_access_message "Only the owner can upload photos."

  before_action :require_owner!

  def show
    @upload_batch = current_user.upload_batches.reviewing.order(created_at: :desc).first
    @upload_batch_counts = @upload_batch&.summary_counts
    @failed_drive_archive_count = current_user.photos.joins(:drive_archive_object).where(drive_archive_objects: { status: "failed" }).count
  end
end
