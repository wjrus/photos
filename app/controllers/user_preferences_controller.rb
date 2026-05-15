class UserPreferencesController < ApplicationController
  owner_access_message "Only the owner can change display preferences."

  before_action :require_owner!

  def update
    current_user.update!(preference_params)
    redirect_to safe_return_path(default: root_path), notice: "Preferences updated."
  end

  private

  def preference_params
    params.require(:user).permit(:show_stream_metadata)
  end
end
