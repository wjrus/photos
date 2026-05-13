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
end
