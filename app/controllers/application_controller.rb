class ApplicationController < ActionController::Base
  include CacheAudience

  class_attribute :owner_required_message, default: "Only the owner can do that."

  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  # Changes to the importmap will invalidate the etag for HTML responses
  stale_when_importmap_changes

  helper_method :current_user, :signed_in?, :privileged_metadata_viewer?

  private

  PHOTO_RETURN_TO_COOKIE = :photos_return_to

  def self.owner_access_message(message)
    self.owner_required_message = message
  end

  def current_user
    @current_user ||= session_user || remembered_user
  end

  def signed_in?
    current_user.present?
  end

  def privileged_metadata_viewer?
    current_user&.trusted_viewer?
  end

  def require_owner!
    return if current_user&.owner?

    if owner_access_json_response?
      render json: { error: owner_required_message }, status: :forbidden
    else
      redirect_to root_path, alert: owner_required_message
    end
  end

  def safe_return_path(default: root_path)
    return_to = params[:return_to].presence || cookies[PHOTO_RETURN_TO_COOKIE].presence
    return default if return_to.blank?

    uri = URI.parse(return_to)
    return return_to if uri.relative?

    default
  rescue URI::InvalidURIError
    default
  end

  def store_photo_return_path(path)
    uri = URI.parse(path.to_s)
    return unless uri.relative?

    cookies[PHOTO_RETURN_TO_COOKIE] = {
      value: path,
      expires: 1.day.from_now,
      same_site: :lax,
      secure: Rails.env.production?
    }
  rescue URI::InvalidURIError
    nil
  end

  def owner_access_json_response?
    request.format.json?
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
