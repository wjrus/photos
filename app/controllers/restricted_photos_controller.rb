class RestrictedPhotosController < ApplicationController
  include PhotoStreamPagination

  owner_access_message "Only the owner can open that page."

  before_action :require_owner!

  def index
    unless restricted_photos_password_configured?
      redirect_to root_path, alert: "Access is not configured."
      return
    end

    return unless restricted_photos_unlocked?

    restricted_stream = current_user.photos.restricted
    @photos, @next_cursor, @newer_cursor = paginate_photo_stream_with_focus(restricted_stream.with_original_variant_records.stream_order)

    return if render_photo_page_if_requested(
      return_to: restricted_photos_path,
      bulk_form_id: nil,
      owner_controls: false,
      next_page_path: restricted_photos_path
    )

    @photo_count = restricted_stream.count
  end

  def unlock
    unless restricted_photos_password_configured?
      redirect_to root_path, alert: "Access is not configured."
      return
    end

    if restricted_photos_password_matches?(params[:password])
      session[:restricted_photos_unlocked] = true
      redirect_to restricted_photos_path, notice: "Unlocked."
    else
      session.delete(:restricted_photos_unlocked)
      redirect_to restricted_photos_path, alert: "Password did not match."
    end
  end

  def lock
    session.delete(:restricted_photos_unlocked)
    redirect_to root_path, notice: "Locked."
  end

  private
end
