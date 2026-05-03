class SessionsController < ApplicationController
  def new
  end

  def create
    user = User.from_omniauth(request.env.fetch("omniauth.auth"))
    sign_in(user)
    redirect_to root_path, notice: "Signed in as #{user.display_name}."
  end

  def password
    user = User.authenticate_by_email(params[:email], params[:password])

    if user
      sign_in(user, remember: params[:remember_me] == "1")
      redirect_to root_path, notice: "Signed in as #{user.display_name}."
    else
      redirect_to sign_in_path, alert: "Email or password was not recognized."
    end
  end

  def destroy
    sign_out
    redirect_to root_path, notice: "Signed out."
  end

  def failure
    redirect_to root_path, alert: "Google sign-in was not completed."
  end
end
