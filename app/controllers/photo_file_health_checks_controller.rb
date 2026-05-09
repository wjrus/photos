class PhotoFileHealthChecksController < ApplicationController
  owner_access_message "Only the owner can check repository health."

  before_action :require_owner!
  before_action :set_photo

  def create
    OriginalFileHealthCheckJob.perform_later(@photo)
    redirect_to safe_return_path(default: photo_path(@photo)), notice: "File health check queued."
  end

  private

  def set_photo
    @photo = current_user.photos.find(params[:photo_id])
  end
end
