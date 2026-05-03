require "test_helper"

class InvitationsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @invited = User.invite!(email: "local@example.com", name: "Local Friend", invited_by: users(:one))
  end

  test "invited user can set a password and sign in" do
    patch accept_invitation_path(@invited.invitation_url_token), params: {
      user: {
        password: "correct horse battery staple",
        password_confirmation: "correct horse battery staple",
        avatar: Rack::Test::UploadedFile.new(Rails.root.join("public/icon.png"), "image/png")
      },
      remember_me: "1"
    }

    assert_redirected_to root_path
    assert_predicate @invited.reload, :invite_accepted?
    assert @invited.password_digest.present?
    assert @invited.remember_token_digest.present?
    assert @invited.avatar.attached?
  end

  test "password sign in accepts remembered users" do
    @invited.accept_invitation!(password: "correct horse battery staple", password_confirmation: "correct horse battery staple")

    post password_sign_in_path, params: {
      email: @invited.email,
      password: "correct horse battery staple",
      remember_me: "1"
    }

    assert_redirected_to root_path
    assert @invited.reload.remember_token_digest.present?
  end
end
