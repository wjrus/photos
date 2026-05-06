class UploadBatchesController < ApplicationController
  owner_access_message "Only the owner can manage upload batches."

  before_action :require_owner!
  before_action :set_upload_batch

  def commit
    count = @upload_batch.photos.count
    @upload_batch.commit!
    redirect_to uploads_path, notice: "Committed upload batch with #{count} item#{'s' unless count == 1}."
  end

  def rollback
    count = @upload_batch.photos.count
    @upload_batch.rollback!
    redirect_to uploads_path, notice: "Undid upload batch and removed #{count} item#{'s' unless count == 1}."
  end

  private

  def set_upload_batch
    @upload_batch = current_user.upload_batches.reviewing.find(params[:id])
  end
end
