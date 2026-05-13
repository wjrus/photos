require "test_helper"

class UsersControllerTest < ActionDispatch::IntegrationTest
  setup do
    OmniAuth.config.test_mode = true
    MailgunClient.clear_deliveries
    @owner = users(:one)
    sign_in_as(@owner)
  end

  teardown do
    OmniAuth.config.mock_auth[:google_oauth2] = nil
    OmniAuth.config.test_mode = false
  end

  test "owner can invite a user and send an invitation email" do
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
    assert_equal 1, MailgunClient.deliveries.size
    assert_equal "ada@example.com", MailgunClient.deliveries.last.to
    assert_includes MailgunClient.deliveries.last.text, invitation_path(invited.invitation_url_token)

    follow_redirect!
    assert_response :success
    assert_includes response.body, invitation_url(invited.invitation_url_token)
  end

  test "owner can resend invitation and send password reset" do
    user = User.invite!(email: "links@example.com", name: "Links", invited_by: @owner)

    assert_difference "MailgunClient.deliveries.size", 1 do
      post send_invitation_user_path(user)
    end
    assert_redirected_to users_path
    assert_includes MailgunClient.deliveries.last.text, invitation_path(user.invitation_url_token)

    assert_difference "MailgunClient.deliveries.size", 1 do
      post send_password_reset_user_path(user)
    end
    assert_redirected_to users_path
    assert_predicate user.reload, :password_reset_valid?
    token = MailgunClient.deliveries.last.text[%r{/password_reset/([^ \s]+)}, 1]
    assert_predicate User.find_by_password_reset_token(token), :present?
    assert_includes MailgunClient.deliveries.last.text, edit_password_reset_path(token)
  end

  test "users page is paginated and lists shared albums" do
    album = @owner.photo_albums.create!(title: "Shared Trip", source: "manual")
    viewer = users(:two)
    album.photo_album_shares.create!(user: viewer, shared_by: @owner)
    15.times { |index| User.invite!(email: "viewer#{index}@example.com", invited_by: @owner) }

    get users_path

    assert_response :success
    assert_includes response.body, "Page 1 of"
    assert_includes response.body, "Shared Trip"
    assert_select "tbody tr", count: 12
  end

  test "owner can remove an album share from the users page" do
    album = @owner.photo_albums.create!(title: "Shared Trip", source: "manual")
    viewer = users(:two)
    share = album.photo_album_shares.create!(user: viewer, shared_by: @owner)

    get users_path

    assert_response :success
    assert_select "button[aria-label=?]", "Stop sharing Shared Trip with #{viewer.display_name}"
    assert_select "div[role='dialog'][aria-labelledby='remove-share-#{share.id}-title']"

    assert_difference "PhotoAlbumShare.count", -1 do
      delete album_share_path(share), params: { return_to: users_path }
    end

    assert_redirected_to users_path
    assert_nil PhotoAlbumShare.find_by(id: share.id)
  end

  test "non owner cannot invite users" do
    sign_in_as(users(:two))

    get users_path

    assert_redirected_to root_path
  end

  test "owner can remove a viewer user with confirmation controls" do
    user = User.invite!(email: "remove-me@example.com", name: "Remove Me", invited_by: @owner)

    get users_path
    assert_response :success
    assert_select "button", text: "Remove"
    assert_select "div[role='dialog'][aria-labelledby='remove-user-#{user.id}-title']"

    assert_difference "User.count", -1 do
      delete user_path(user)
    end

    assert_redirected_to users_path
    assert_nil User.find_by(id: user.id)
  end

  test "owner cannot remove owner account" do
    assert_no_difference "User.count" do
      delete user_path(@owner)
    end

    assert_redirected_to users_path
    assert_predicate @owner.reload, :owner?
  end

  test "non owner cannot remove users" do
    user = User.invite!(email: "not-yours@example.com", name: "Not Yours", invited_by: @owner)
    sign_in_as(users(:two))

    assert_no_difference "User.count" do
      delete user_path(user)
    end

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
