require "test_helper"

class RestrictedPhotosControllerTest < ActionDispatch::IntegrationTest
  setup do
    OmniAuth.config.test_mode = true
    @owner = users(:one)
    @password = ENV["PHOTOS_LOCKED_FOLDER_PASSWORD"]
    ENV["PHOTOS_LOCKED_FOLDER_PASSWORD"] = "open-sesame"
    sign_in_as(@owner)
  end

  teardown do
    ENV["PHOTOS_LOCKED_FOLDER_PASSWORD"] = @password
    OmniAuth.config.mock_auth[:google_oauth2] = nil
    OmniAuth.config.test_mode = false
  end

  test "owner sees password form before unlocking" do
    photo = attached_photo(title: "Private item", restricted: true)

    get restricted_photos_path

    assert_response :success
    assert_includes response.body, "Password"
    refute_includes response.body, photo.title
  end

  test "owner unlocks restricted photos for the session" do
    photo = attached_photo(title: "Private item", restricted: true)

    post unlock_restricted_photos_path, params: { password: "open-sesame" }
    assert_redirected_to restricted_photos_path

    get restricted_photos_path
    assert_response :success
    assert_includes response.body, photo.title
    assert_select "form[action='#{lock_restricted_photos_path}']"
  end

  test "bad password keeps restricted photos hidden" do
    photo = attached_photo(title: "Private item", restricted: true)

    post unlock_restricted_photos_path, params: { password: "wrong" }
    assert_redirected_to restricted_photos_path

    get restricted_photos_path
    assert_response :success
    refute_includes response.body, photo.title
  end

  test "non owner cannot open restricted route" do
    delete sign_out_path
    sign_in_as(users(:two))

    get restricted_photos_path

    assert_redirected_to root_path
  end

  test "restricted photos are not available through normal photo routes until unlocked" do
    photo = attached_photo(title: "Private item", restricted: true)

    get photo_path(photo)
    assert_response :not_found

    get display_photo_path(photo)
    assert_response :not_found

    get media_photo_path(photo)
    assert_response :not_found

    post unlock_restricted_photos_path, params: { password: "open-sesame" }
    get photo_path(photo, return_to: restricted_photos_path)
    assert_redirected_to photo_path(photo)
    follow_redirect!
    assert_response :success
  end

  test "locking blocks page fragments as well as the full private feed" do
    photo = attached_photo(title: "Protected page item", restricted: true)
    post unlock_restricted_photos_path, params: { password: "open-sesame" }
    get restricted_photos_path(stream_page: 1)
    assert_response :success
    assert_select "[data-photo-id='#{photo.id}']"
    assert_select "main", count: 0

    delete lock_restricted_photos_path
    get restricted_photos_path(stream_page: 1, photo_id: photo.id)
    assert_response :success
    assert_select "[data-photo-id]", count: 0
    refute_includes response.body, photo.title
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

  def attached_photo(title:, restricted:)
    photo = @owner.photos.new(title: title, restricted: restricted)
    photo.original.attach(
      io: File.open(Rails.root.join("public/icon.png")),
      filename: "#{title.parameterize}.png",
      content_type: "image/png"
    )
    photo.save!
    photo
  end
end
