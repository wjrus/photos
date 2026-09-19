class SessionsController < ApplicationController
  rate_limit to: 10, within: 3.minutes, only: :password, name: "ip",
    with: -> { authentication_rate_limited(retry_after: 3.minutes) }
  rate_limit to: 10, within: 15.minutes, only: :password, name: "email", by: :authentication_email_key,
    with: -> { authentication_rate_limited(retry_after: 15.minutes) }

  def new
  end

  def create
    user = User.from_omniauth(request.env.fetch("omniauth.auth"))
    sign_in(user)
    redirect_to omniauth_return_path, notice: "Signed in as #{user.display_name}."
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

  private

  def omniauth_return_path
    origin = request.env["omniauth.origin"].presence
    return origin if safe_internal_path?(origin)

    root_path
  end
end
