require "test_helper"

class UploadsControllerTest < ActionDispatch::IntegrationTest
  setup do
    OmniAuth.config.test_mode = true
  end

  teardown do
    OmniAuth.config.mock_auth[:google_oauth2] = nil
    OmniAuth.config.test_mode = false
  end

  test "owner can view upload page" do
    sign_in_as(users(:one))

    get uploads_path

    assert_response :success
    assert_includes response.body, "Drop files here"
    assert_includes response.body, "HEIC JPG PNG MOV MP4 AAE"
  end

  test "owner sees reviewing upload batch on upload page" do
    owner = users(:one)
    batch = UploadBatch.create!(owner: owner)
    photo = owner.photos.new(upload_batch: batch)
    photo.original.attach(Rack::Test::UploadedFile.new(Rails.root.join("public/icon.png"), "image/png"))
    photo.save!
    sign_in_as(owner)

    get uploads_path

    assert_response :success
    assert_includes response.body, "Upload batch"
    assert_includes response.body, "Commit upload"
    assert_includes response.body, "Undo upload"
    assert_includes response.body, "1 photo"
  end

  test "non owner cannot view upload page" do
    sign_in_as(users(:two))

    get uploads_path

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
