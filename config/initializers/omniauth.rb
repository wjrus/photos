Rails.application.config.middleware.use OmniAuth::Builder do
  provider :google_oauth2,
    ENV["GOOGLE_CLIENT_ID"],
    ENV["GOOGLE_CLIENT_SECRET"],
    {
      access_type: "offline",
      prompt: "select_account",
      scope: "openid,email,profile,https://www.googleapis.com/auth/drive"
    }
end

OmniAuth.config.allowed_request_methods = [ :post ]
