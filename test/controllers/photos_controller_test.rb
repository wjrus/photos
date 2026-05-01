require "test_helper"

class PhotosControllerTest < ActionDispatch::IntegrationTest
  setup do
    OmniAuth.config.test_mode = true
    @owner = users(:one)
    sign_in_as(@owner)
  end

  teardown do
    OmniAuth.config.mock_auth[:google_oauth2] = nil
    OmniAuth.config.test_mode = false
  end

  test "owner uploads a private original" do
    assert_difference "Photo.count", 1 do
      post photos_path, params: {
        photo: {
          title: "First upload",
          original: fixture_upload("public/icon.png", "image/png")
        }
      }
    end

    photo = Photo.order(:created_at).last
    assert_redirected_to root_path
    assert_equal @owner, photo.owner
    assert_equal "private", photo.visibility
    assert_predicate photo.original, :attached?
  end

  test "owner can publish and unpublish a photo" do
    photo = attached_photo

    patch publish_photo_path(photo)
    assert_redirected_to root_path
    assert_predicate photo.reload, :public?

    patch unpublish_photo_path(photo)
    assert_redirected_to root_path
    assert_predicate photo.reload, :private?
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

  def fixture_upload(path, content_type)
    Rack::Test::UploadedFile.new(Rails.root.join(path), content_type)
  end

  def attached_photo
    photo = @owner.photos.new
    photo.original.attach(
      io: File.open(Rails.root.join("public/icon.png")),
      filename: "fixture.png",
      content_type: "image/png"
    )
    photo.save!
    photo
  end
end
