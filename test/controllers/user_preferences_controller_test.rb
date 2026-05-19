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

  test "owner can change stream tile size preference" do
    patch user_preferences_path, params: {
      return_to: root_path,
      user: { stream_tile_size: "large" }
    }

    assert_redirected_to root_path
    assert_equal "large", @owner.reload.stream_tile_size
  end

  test "invalid stream tile size is rejected" do
    patch user_preferences_path, params: {
      user: { stream_tile_size: "enormous" }
    }

    assert_redirected_to root_path
    assert_equal "medium", @owner.reload.stream_tile_size
  end

  test "viewer cannot change preferences" do
    sign_in_as(users(:two))

    patch user_preferences_path, params: {
      user: { show_stream_metadata: "1", stream_tile_size: "large" }
    }

    assert_redirected_to root_path
    refute_predicate users(:two).reload, :show_stream_metadata?
    assert_equal "medium", users(:two).reload.stream_tile_size
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
