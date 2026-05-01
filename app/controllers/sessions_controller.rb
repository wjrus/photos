class SessionsController < ApplicationController
  def create
    user = User.from_omniauth(request.env.fetch("omniauth.auth"))
    reset_session
    session[:user_id] = user.id
    redirect_to root_path, notice: "Signed in as #{user.display_name}."
  end

  def destroy
    reset_session
    redirect_to root_path, notice: "Signed out."
  end

  def failure
    redirect_to root_path, alert: "Google sign-in was not completed."
  end
end
