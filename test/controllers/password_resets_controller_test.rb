require "test_helper"

class PasswordResetsControllerTest < ActionDispatch::IntegrationTest
  setup do
    MailgunClient.clear_deliveries
    @user = users(:two)
  end

  test "requesting reset sends a generic response and email for known users" do
    assert_difference "MailgunClient.deliveries.size", 1 do
      post password_reset_path, params: { email: @user.email.upcase }
    end

    assert_redirected_to sign_in_path
    assert_equal @user.email, MailgunClient.deliveries.last.to
    token = MailgunClient.deliveries.last.text[%r{/password_reset/([^ \s]+)}, 1]
    assert_predicate User.find_by_password_reset_token(token), :present?
  end

  test "requesting reset does not reveal unknown emails" do
    assert_no_difference "MailgunClient.deliveries.size" do
      post password_reset_path, params: { email: "unknown@example.com" }
    end

    assert_redirected_to sign_in_path
  end

  test "valid reset token opens the password form" do
    token = @user.generate_password_reset_token!

    get edit_password_reset_path(token)

    assert_response :success
    assert_includes response.body, update_password_reset_path(token)
  end

  test "invalid reset token redirects to reset request" do
    get edit_password_reset_path("not-real")

    assert_redirected_to new_password_reset_path
  end

  test "invalid password does not consume the reset token" do
    token = @user.generate_password_reset_token!

    patch update_password_reset_path(token), params: {
      user: {
        password: "short",
        password_confirmation: "short"
      }
    }

    assert_response :unprocessable_entity
    assert_predicate User.find_by_password_reset_token(token), :present?
  end

  test "successful reset consumes token and signs user in" do
    token = @user.generate_password_reset_token!

    patch update_password_reset_path(token), params: {
      user: {
        password: "correct horse battery staple",
        password_confirmation: "correct horse battery staple"
      }
    }

    assert_redirected_to root_path
    assert_nil User.find_by_password_reset_token(token)
    assert User.authenticate_by_email(@user.email, "correct horse battery staple")
  end

  test "google users can set a password by reset" do
    google_user = users(:one)
    token = google_user.generate_password_reset_token!

    patch update_password_reset_path(token), params: {
      user: {
        password: "another correct password",
        password_confirmation: "another correct password"
      }
    }

    assert_redirected_to root_path
    assert User.authenticate_by_email(google_user.email, "another correct password")
  end

  test "mismatched confirmation preserves the password and reset token" do
    @user.update!(password: "old synthetic password", password_confirmation: "old synthetic password")
    token = @user.generate_password_reset_token!
    digest = @user.password_digest

    patch update_password_reset_path(token), params: {
      user: { password: "a new synthetic password", password_confirmation: "different password" }
    }

    assert_response :unprocessable_entity
    assert_equal digest, @user.reload.password_digest
    assert_predicate User.find_by_password_reset_token(token), :present?
  end

  test "password reset revokes other sessions and remembered browsers" do
    owner = users(:one)
    owner.update!(password: "old synthetic password", password_confirmation: "old synthetic password")
    old_browser = open_session
    old_browser.post password_sign_in_path, params: { email: owner.email, password: "old synthetic password", remember_me: "1" }
    old_browser.get uploads_path
    assert_equal 200, old_browser.response.status

    remembered_browser = open_session
    remembered_browser.cookies[:remember_user_id] = old_browser.cookies[:remember_user_id]
    remembered_browser.cookies[:remember_token] = old_browser.cookies[:remember_token]
    token = owner.generate_password_reset_token!

    patch update_password_reset_path(token), params: {
      user: { password: "new synthetic password", password_confirmation: "new synthetic password" }
    }

    assert_redirected_to root_path
    get uploads_path
    assert_response :success
    assert_nil owner.reload.remember_token_digest

    old_browser.get uploads_path
    assert_equal 302, old_browser.response.status
    remembered_browser.get uploads_path
    assert_equal 302, remembered_browser.response.status
  end

  test "resetting a google-only password invalidates an existing session" do
    owner = users(:one)
    assert_nil owner.password_digest
    old_browser = open_session
    OmniAuth.config.test_mode = true
    OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new(
      provider: owner.provider, uid: owner.uid, info: { email: owner.email, name: owner.name }
    )
    old_browser.post "/auth/google_oauth2"
    old_browser.follow_redirect!
    old_browser.get uploads_path
    assert_equal 200, old_browser.response.status

    token = owner.generate_password_reset_token!
    patch update_password_reset_path(token), params: {
      user: { password: "new synthetic password", password_confirmation: "new synthetic password" }, remember_me: "1"
    }

    assert_redirected_to root_path
    assert_predicate owner.reload.remember_token_digest, :present?
    old_browser.get uploads_path
    assert_equal 302, old_browser.response.status
  ensure
    OmniAuth.config.mock_auth[:google_oauth2] = nil
    OmniAuth.config.test_mode = false
  end
end
