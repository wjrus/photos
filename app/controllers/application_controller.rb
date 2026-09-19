class ApplicationController < ActionController::Base
  include CacheAudience

  class_attribute :owner_required_message, default: "Only the owner can do that."

  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  # Changes to the importmap will invalidate the etag for HTML responses
  stale_when_importmap_changes

  before_action :record_user_access

  helper_method :current_user, :signed_in?, :privileged_metadata_viewer?, :repository_unread_event_count

  private

  PHOTO_RETURN_TO_COOKIE = :photos_return_to
  USER_ACCESS_UPDATE_INTERVAL = 5.minutes

  def self.owner_access_message(message)
    self.owner_required_message = message
  end

  def current_user
    @current_user ||= session_user || remembered_user
  end

  def signed_in?
    current_user.present?
  end

  def record_user_access
    user = current_user
    return unless user
    return if user.last_accessed_at.present? && user.last_accessed_at > USER_ACCESS_UPDATE_INTERVAL.ago

    now = Time.current
    user.update_column(:last_accessed_at, now)
    user.last_accessed_at = now
  end

  def privileged_metadata_viewer?
    current_user&.trusted_viewer?
  end

  def repository_unread_event_count
    return 0 unless current_user&.owner?

    @repository_unread_event_count ||= RepositoryEvent.unread.count
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
    return return_to if safe_internal_path?(return_to)

    default
  end

  def store_photo_return_path(path)
    return unless safe_internal_path?(path)

    cookies[PHOTO_RETURN_TO_COOKIE] = {
      value: path,
      expires: 1.day.from_now,
      same_site: :lax,
      secure: Rails.env.production?
    }
  end

  def safe_internal_path?(value)
    path = value.to_s
    return false unless path.start_with?("/")
    return false if path.start_with?("//") || path.include?("\\")

    uri = URI.parse(path)
    uri.scheme.nil? && uri.host.nil? && uri.path.start_with?("/")
  rescue URI::InvalidURIError
    false
  end

  def owner_access_json_response?
    request.format.json?
  end

  def sign_in(user, remember: false)
    start_user_session(user)
    cookies.delete(:remember_user_id)
    cookies.delete(:remember_token)
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
    return unless session[:user_id]

    user = User.find_by(id: session[:user_id])
    if user && ActiveSupport::SecurityUtils.secure_compare(session[:authentication_fingerprint].to_s, user.authentication_fingerprint)
      return user
    end

    reset_session
    nil
  end

  def remembered_user
    user_id = cookies.signed[:remember_user_id]
    token = cookies.signed[:remember_token]
    user = User.find_by(id: user_id)
    return unless user&.remembered?(token)

    start_user_session(user)
    user
  end

  def start_user_session(user)
    reset_session
    session[:user_id] = user.id
    session[:authentication_fingerprint] = user.authentication_fingerprint
    @current_user = user
  end

  def authentication_email_key
    Digest::SHA256.hexdigest(params[:email].to_s.strip.downcase)
  end

  def authentication_rate_limited(retry_after:)
    response.set_header("Retry-After", retry_after.to_i.to_s)
    render plain: "Too many attempts. Please try again later.", status: :too_many_requests
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
