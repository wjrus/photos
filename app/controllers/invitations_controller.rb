class InvitationsController < ApplicationController
  before_action :set_invited_user

  def show
  end

  def update
    if invitation_params[:password].blank?
      @user.errors.add(:password, "can't be blank")
      flash.now[:alert] = @user.errors.full_messages.to_sentence
      render :show, status: :unprocessable_entity
      return
    end

    @user.accept_invitation!(password: invitation_params[:password], password_confirmation: invitation_params[:password_confirmation])
    @user.avatar.attach(invitation_params[:avatar]) if invitation_params[:avatar].present?
    sign_in(@user, remember: params[:remember_me] == "1")
    redirect_to root_path, notice: "Signed in as #{@user.display_name}."
  rescue ActiveRecord::RecordInvalid => e
    flash.now[:alert] = e.record.errors.full_messages.to_sentence
    render :show, status: :unprocessable_entity
  end

  private

  def set_invited_user
    @user = User.find_signed!(params[:token], purpose: :invitation)
  rescue ActiveSupport::MessageVerifier::InvalidSignature
    redirect_to sign_in_path, alert: "That invitation link is invalid."
  end

  def invitation_params
    params.require(:user).permit(:password, :password_confirmation, :avatar)
  end
end
