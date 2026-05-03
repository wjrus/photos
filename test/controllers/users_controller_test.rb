require "test_helper"

class UsersControllerTest < ActionDispatch::IntegrationTest
  setup do
    OmniAuth.config.test_mode = true
    @owner = users(:one)
    sign_in_as(@owner)
  end

  teardown do
    OmniAuth.config.mock_auth[:google_oauth2] = nil
    OmniAuth.config.test_mode = false
  end

  test "owner can invite a user and copy an invitation link" do
    assert_difference "User.count", 1 do
      post users_path, params: {
        user: {
          first_name: "Ada",
          last_name: "Lovelace",
          email: "ada@example.com"
        }
      }
    end

    invited = User.find_by!(email: "ada@example.com")
    assert_equal "Ada Lovelace", invited.name
    assert_predicate invited, :invited_pending?
    assert_equal @owner, invited.invited_by

    follow_redirect!
    assert_response :success
    assert_includes response.body, invitation_url(invited.invitation_url_token)
  end

  test "non owner cannot invite users" do
    sign_in_as(users(:two))

    get users_path

    assert_redirected_to root_path
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
