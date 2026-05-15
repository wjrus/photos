require "test_helper"

class UserPreferencesControllerTest < ActionDispatch::IntegrationTest
  setup do
    OmniAuth.config.test_mode = true
    @owner = users(:one)
    sign_in_as(@owner)
  end

  teardown do
    OmniAuth.config.mock_auth[:google_oauth2] = nil
    OmniAuth.config.test_mode = false
  end

  test "owner can toggle stream metadata preference" do
    patch user_preferences_path, params: {
      return_to: users_path,
      user: { show_stream_metadata: "1" }
    }

    assert_redirected_to users_path
    assert_predicate @owner.reload, :show_stream_metadata?
  end

  test "viewer cannot change preferences" do
    sign_in_as(users(:two))

    patch user_preferences_path, params: {
      user: { show_stream_metadata: "1" }
    }

    assert_redirected_to root_path
    refute_predicate users(:two).reload, :show_stream_metadata?
  end

  private

  def sign_in_as(user)
    OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new(
      provider: user.provider,
      uid: user.uid,
      info: { email: user.email, name: user.name, image: user.avatar_url }
    )
    post "/auth/google_oauth2"
    follow_redirect!
  end
end
