class UsersController < ApplicationController
  owner_access_message "Only the owner can manage users."

  before_action :require_owner!

  def index
    @page = [ params[:page].to_i, 1 ].max
    @per_page = 12
    @user_count = User.count
    @page_count = (@user_count.to_f / @per_page).ceil
    @users = User
      .includes(photo_album_shares: :photo_album)
      .order(Arel.sql("LOWER(email) ASC"))
      .offset((@page - 1) * @per_page)
      .limit(@per_page)
    @invite = User.new
  end

  def create
    user = User.invite!(
      email: invite_params[:email],
      name: [ invite_params[:first_name], invite_params[:last_name] ].compact_blank.join(" "),
      invited_by: current_user
    )

    UserNotificationMailer.invitation(user)
    redirect_to users_path(invited_user_id: user.id), notice: "Invitation sent to #{user.display_name}."
  rescue ActiveRecord::RecordInvalid => e
    redirect_to users_path, alert: e.record.errors.full_messages.to_sentence
  rescue MailgunClient::DeliveryError => e
    Rails.logger.error("Invitation email failed: #{e.message}")
    redirect_to users_path(invited_user_id: user&.id), alert: "Invitation was saved, but the email could not be sent."
  end

  def send_invitation
    user = User.find(params[:id])
    return redirect_to users_path, alert: "That user has already accepted their invitation." unless user.invited_pending?

    UserNotificationMailer.invitation(user)
    redirect_to users_path(page: params[:page]), notice: "Invitation sent to #{user.display_name}."
  rescue MailgunClient::DeliveryError => e
    Rails.logger.error("Invitation email failed: #{e.message}")
    redirect_to users_path(page: params[:page]), alert: "The invitation email could not be sent."
  end

  def send_password_reset
    user = User.find(params[:id])
    token = user.generate_password_reset_token!
    UserNotificationMailer.password_reset(user, token)
    redirect_to users_path(page: params[:page]), notice: "Password reset sent to #{user.display_name}."
  rescue MailgunClient::DeliveryError => e
    Rails.logger.error("Password reset email failed: #{e.message}")
    redirect_to users_path(page: params[:page]), alert: "The password reset email could not be sent."
  end

  def destroy
    user = User.find(params[:id])
    return redirect_to users_path, alert: "You cannot remove the owner account." if user.owner?
    return redirect_to users_path, alert: "You cannot remove your own account." if user == current_user

    user.destroy!
    redirect_to users_path, notice: "#{user.display_name} was removed."
  rescue ActiveRecord::DeleteRestrictionError
    redirect_to users_path, alert: "That user owns content and cannot be removed."
  end

  private

  def invite_params
    params.require(:user).permit(:first_name, :last_name, :email)
  end
end
