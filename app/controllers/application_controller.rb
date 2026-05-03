class ApplicationController < ActionController::Base
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  # Changes to the importmap will invalidate the etag for HTML responses
  stale_when_importmap_changes

  helper_method :current_user, :signed_in?, :privileged_metadata_viewer?

  private

  def current_user
    @current_user ||= session_user || remembered_user
  end

  def signed_in?
    current_user.present?
  end

  def privileged_metadata_viewer?
    current_user&.trusted_viewer?
  end

  def sign_in(user, remember: false)
    reset_session
    session[:user_id] = user.id
    remember_user(user) if remember
  end

  def sign_out
    current_user&.forget!
    cookies.delete(:remember_user_id)
    cookies.delete(:remember_token)
    reset_session
    @current_user = nil
  end

  def session_user
    User.find_by(id: session[:user_id]) if session[:user_id]
  end

  def remembered_user
    user_id = cookies.signed[:remember_user_id]
    token = cookies.signed[:remember_token]
    user = User.find_by(id: user_id)
    return unless user&.remembered?(token)

    session[:user_id] = user.id
    user
  end

  def remember_user(user)
    token = user.remember!
    cookies.permanent.signed[:remember_user_id] = {
      value: user.id,
      httponly: true,
      same_site: :lax,
      secure: Rails.env.production?
    }
    cookies.permanent.signed[:remember_token] = {
      value: token,
      httponly: true,
      same_site: :lax,
      secure: Rails.env.production?
    }
  end

  def restricted_photos_unlocked?
    current_user&.owner? && session[:restricted_photos_unlocked] == true
  end

  def restricted_photos_password_configured?
    ENV["PHOTOS_LOCKED_FOLDER_PASSWORD"].present?
  end

  def restricted_photos_password_matches?(candidate)
    password = ENV["PHOTOS_LOCKED_FOLDER_PASSWORD"].to_s
    return false if password.blank? || candidate.blank?

    ActiveSupport::SecurityUtils.secure_compare(
      Digest::SHA256.hexdigest(candidate.to_s),
      Digest::SHA256.hexdigest(password)
    )
  end
end
