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

  test "owner uploads a private mov original" do
    assert_difference "Photo.count", 1 do
      post photos_path, params: {
        photo: {
          original: Rack::Test::UploadedFile.new(StringIO.new("fake mov bytes"), "video/quicktime", original_filename: "live-photo.mov")
        }
      }
    end

    photo = Photo.order(:created_at).last
    assert_redirected_to root_path
    assert_equal "video/quicktime", photo.content_type
    assert_equal "Live photo", photo.title
    assert_predicate photo, :video?
  end

  test "owner uploads a private mp4 original" do
    assert_difference "Photo.count", 1 do
      post photos_path, params: {
        photo: {
          original: Rack::Test::UploadedFile.new(StringIO.new("fake mp4 bytes"), "video/mp4", original_filename: "clip.mp4")
        }
      }
    end

    photo = Photo.order(:created_at).last
    assert_redirected_to root_path
    assert_equal "video/mp4", photo.content_type
    assert_predicate photo, :video?
  end

  test "owner uploads aae sidecar with original" do
    assert_difference "Photo.count", 1 do
      post photos_path, params: {
        photo: {
          original: fixture_upload("public/icon.png", "image/png"),
          sidecars: [
            Rack::Test::UploadedFile.new(StringIO.new("<?xml version=\"1.0\"?>"), "application/xml", original_filename: "IMG_0001.AAE")
          ]
        }
      }
    end

    photo = Photo.order(:created_at).last
    assert_redirected_to root_path
    assert_equal 1, photo.sidecar_count
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

  test "owner sees archive and metadata details" do
    photo = attached_photo
    photo.create_metadata!(extraction_status: "complete", camera_make: "Fuji", camera_model: "X100", raw: {})

    get photo_path(photo)

    assert_response :success
    assert_includes response.body, "Archive"
    assert_includes response.body, "Fuji X100"
    assert_includes response.body, photo.original_filename
  end

  test "public viewer sees public display without privileged metadata" do
    photo = attached_photo
    photo.create_metadata!(extraction_status: "complete", camera_make: "Fuji", camera_model: "X100", raw: {})
    photo.publish!
    delete sign_out_path

    get photo_path(photo)

    assert_response :success
    assert_includes response.body, photo.title
    refute_includes response.body, "Archive"
    refute_includes response.body, "Fuji X100"
    refute_includes response.body, photo.original_filename
  end

  test "video detail renders a video player" do
    photo = attached_video
    photo.publish!
    delete sign_out_path

    get photo_path(photo)

    assert_response :success
    assert_includes response.body, "<video"
    assert_includes response.body, "controls"
    refute_includes response.body, photo.original_filename
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

  def attached_video
    photo = @owner.photos.new
    photo.original.attach(
      io: StringIO.new("fake mov bytes"),
      filename: "clip.mov",
      content_type: "video/quicktime"
    )
    photo.save!
    photo
  end
end
