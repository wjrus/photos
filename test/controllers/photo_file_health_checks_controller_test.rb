require "test_helper"

class PhotoFileHealthChecksControllerTest < ActionDispatch::IntegrationTest
  setup do
    OmniAuth.config.test_mode = true
    @owner = users(:one)
    sign_in_as(@owner)
    @photo = attached_photo(@owner)
  end

  teardown do
    OmniAuth.config.mock_auth[:google_oauth2] = nil
    OmniAuth.config.test_mode = false
  end

  test "owner can queue a photo file health check" do
    assert_enqueued_with(job: OriginalFileHealthCheckJob, args: [ @photo ]) do
      post photo_file_health_check_path(@photo), params: { return_to: photo_path(@photo) }
    end

    assert_redirected_to photo_path(@photo)
    assert_equal "File health check queued.", flash[:notice]
  end

  test "non owner cannot queue a photo file health check" do
    delete sign_out_path
    sign_in_as(users(:two))

    post photo_file_health_check_path(@photo)

    assert_redirected_to root_path
  end

  private

  def attached_photo(owner)
    path = Rails.root.join("public/icon.png")
    photo = owner.photos.new(
      checksum_sha256: Digest::SHA256.file(path).hexdigest,
      checksum_status: "complete"
    )
    photo.original.attach(io: File.open(path, "rb"), filename: "fixture.png", content_type: "image/png")
    photo.save!
    photo
  end

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
