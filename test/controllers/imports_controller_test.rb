require "test_helper"

class ImportsControllerTest < ActionDispatch::IntegrationTest
  setup do
    OmniAuth.config.test_mode = true
    @owner = users(:one)
    sign_in_as(@owner)
  end

  teardown do
    OmniAuth.config.mock_auth[:google_oauth2] = nil
    OmniAuth.config.test_mode = false
  end

  test "owner sees import status" do
    GoogleTakeoutImport.create!(
      zip_path: "/rails/imports/google-takeout/takeout-001.zip",
      entry_name: "Takeout/Google Photos/IMG_0001.JPG",
      original_filename: "IMG_0001.JPG",
      status: "imported"
    )
    GoogleTakeoutImport.create!(
      zip_path: "/rails/imports/google-takeout/takeout-001.zip",
      entry_name: "Takeout/Google Photos/bad.JPG",
      original_filename: "bad.JPG",
      status: "failed",
      error: "not today"
    )

    get imports_path

    assert_response :success
    assert_includes response.body, "Import status"
    assert_includes response.body, "takeout-001.zip"
    assert_includes response.body, "not today"
  end

  test "non owner cannot see import status" do
    delete sign_out_path
    sign_in_as(users(:two))

    get imports_path

    assert_redirected_to root_path
  end

  private

  def sign_in_as(user)
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
  end
end
