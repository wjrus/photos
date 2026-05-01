require "test_helper"

class SessionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    OmniAuth.config.test_mode = true
  end

  teardown do
    OmniAuth.config.mock_auth[:google_oauth2] = nil
    OmniAuth.config.test_mode = false
  end

  test "signs in from google callback" do
    OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new(
      provider: "google_oauth2",
      uid: "google-session",
      info: {
        email: "session@example.com",
        name: "Session User",
        image: "https://example.com/session.jpg"
      }
    )

    assert_difference "User.count", 1 do
      post "/auth/google_oauth2"
      follow_redirect!
    end

    assert_redirected_to root_path
    follow_redirect!
    assert_response :success
    assert_includes response.body, "Signed in as Session User"
    assert_includes response.body, "Sign out"
  end

  test "signs out" do
    user = users(:one)
    OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new(
      provider: user.provider,
      uid: user.uid,
      info: {
        email: user.email,
        name: user.name,
        image: user.avatar_url
      }
    )

    post "/auth/google_oauth2"
    follow_redirect!
    delete sign_out_path
    assert_redirected_to root_path
    follow_redirect!
    assert_includes response.body, "Signed out."
    assert_includes response.body, "Sign in"
  end
end
