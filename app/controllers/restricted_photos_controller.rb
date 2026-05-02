class RestrictedPhotosController < ApplicationController
  before_action :require_owner!

  def index
    unless restricted_photos_password_configured?
      redirect_to root_path, alert: "Access is not configured."
      return
    end

    @photos = current_user.photos.restricted.with_attached_original.stream_order if restricted_photos_unlocked?
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

  def require_owner!
    return if current_user&.owner?

    redirect_to root_path, alert: "Only the owner can open that page."
  end
end
