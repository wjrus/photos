class PhotoBulkActionsController < ApplicationController
  include PhotoStreamReturnPaths

  owner_access_message "Only the owner can manage photos."

  before_action :require_owner!

  def create
    photos = selected_photos.to_a
    return redirect_to safe_return_path, alert: "Select at least one photo." if photos.empty?
    removing = %w[archive restore restrict delete remove_from_album].include?(params[:bulk_action]) ||
      (params[:bulk_action] == "unpublish" && public_return_path?)
    focused = params[:bulk_action] == "set_location" ? photos.select(&:image?) : photos
    return_path = bulk_return_path(focused, removing_from_stream: removing)
    result = PhotoBulkOperation.new(owner: current_user, photos: photos, action: params[:bulk_action], attributes: params).call
    redirect_to return_path, notice: result[:message]
  rescue PhotoBulkOperation::InvalidAction => error
    redirect_to safe_return_path, alert: error.message
  rescue ActiveRecord::RecordInvalid => error
    redirect_to safe_return_path, alert: error.record.errors.full_messages.to_sentence
  end

  private

  def selected_photo_ids
    Array(params[:photo_ids]).compact_blank
  end

  def selected_photos
    scope = current_user.photos.where(restricted: false).in_order_of(:id, selected_photo_ids)
    if params[:bulk_action] == "restore" || archive_return_path?(safe_return_path)
      scope.archived
    else
      scope.not_archived
    end
  end

  def bulk_return_path(photos, removing_from_stream: false)
    return_path = safe_return_path
    return return_path if params[:return_to].blank? || photos.empty?

    if removing_from_stream
      photo_stream_return_path_after_removing(photos, return_path: return_path)
    else
      photo_stream_focused_return_path(photos.first, return_path: return_path)
    end
  end

  def archive_return_path?(return_path)
    URI.parse(return_path).path == archived_photos_path
  rescue URI::InvalidURIError
    false
  end

  def public_return_path?
    URI.parse(safe_return_path).path == public_photos_path
  rescue URI::InvalidURIError
    false
  end
end
