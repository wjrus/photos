class UsersController < ApplicationController
  owner_access_message "Only the owner can manage users."

  before_action :require_owner!

  def index
    @users = User.order(Arel.sql("LOWER(email) ASC"))
    @invite = User.new
  end

  def create
    user = User.invite!(
      email: invite_params[:email],
      name: [ invite_params[:first_name], invite_params[:last_name] ].compact_blank.join(" "),
      invited_by: current_user
    )

    redirect_to users_path(invited_user_id: user.id), notice: "Invitation prepared for #{user.display_name}."
  rescue ActiveRecord::RecordInvalid => e
    redirect_to users_path, alert: e.record.errors.full_messages.to_sentence
  end

  private

  def invite_params
    params.require(:user).permit(:first_name, :last_name, :email)
  end
end
