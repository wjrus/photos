class PasswordResetsController < ApplicationController
  before_action :set_user_from_token, only: %i[edit update]

  def new
  end

  def create
    if (user = User.find_by(email: params[:email].to_s.strip.downcase))
      token = user.generate_password_reset_token!
      UserNotificationMailer.password_reset(user, token)
    end

    redirect_to sign_in_path, notice: "If that email can sign in, a reset link has been sent."
  rescue MailgunClient::DeliveryError => e
    Rails.logger.error("Password reset email failed: #{e.message}")
    redirect_to new_password_reset_path, alert: "The reset email could not be sent."
  end

  def edit
  end

  def update
    if password_reset_params[:password].blank?
      @user.errors.add(:password, "can't be blank")
      flash.now[:alert] = @user.errors.full_messages.to_sentence
      render :edit, status: :unprocessable_entity
      return
    end

    @user.reset_password!(password_reset_params)
    sign_in(@user, remember: params[:remember_me] == "1")
    redirect_to root_path, notice: "Password updated."
  rescue ActiveRecord::RecordInvalid => e
    flash.now[:alert] = e.record.errors.full_messages.to_sentence
    render :edit, status: :unprocessable_entity
  end

  private

  def set_user_from_token
    @user = User.find_by_password_reset_token(params[:token])
    redirect_to new_password_reset_path, alert: "That reset link is invalid or expired." unless @user
  end

  def password_reset_params
    params.require(:user).permit(:password, :password_confirmation)
  end
end
