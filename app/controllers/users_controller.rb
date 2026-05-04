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
