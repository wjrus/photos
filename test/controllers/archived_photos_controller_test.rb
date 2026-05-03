require "test_helper"

class ArchivedPhotosControllerTest < ActionDispatch::IntegrationTest
  setup do
    OmniAuth.config.test_mode = true
    @owner = users(:one)
    sign_in_as(@owner)
  end

  teardown do
    OmniAuth.config.mock_auth[:google_oauth2] = nil
    OmniAuth.config.test_mode = false
  end

  test "owner sees archived photos" do
    archived = attached_photo(title: "Screenshot")
    archived.archive!
    active = attached_photo(title: "Vacation")

    get archived_photos_path

    assert_response :success
    assert_includes response.body, "Archive"
    assert_includes response.body, archived.title
    refute_includes response.body, active.title
    assert_select "form#archive-photo-bulk-form"
    assert_select "button[value='restore'][aria-label='Restore selected photos to stream']"
  end

  test "non owner cannot open archive" do
    delete sign_out_path
    sign_in_as(users(:two))

    get archived_photos_path

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

  def attached_photo(title:)
    photo = @owner.photos.new(title: title)
    photo.original.attach(
      io: File.open(Rails.root.join("public/icon.png")),
      filename: "#{title.parameterize}.png",
      content_type: "image/png"
    )
    photo.save!
    photo
  end
end
