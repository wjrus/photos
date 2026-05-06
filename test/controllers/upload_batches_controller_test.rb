require "test_helper"

class UploadBatchesControllerTest < ActionDispatch::IntegrationTest
  setup do
    OmniAuth.config.test_mode = true
    @owner = users(:one)
    sign_in_as(@owner)
  end

  teardown do
    OmniAuth.config.mock_auth[:google_oauth2] = nil
    OmniAuth.config.test_mode = false
  end

  test "owner can commit a reviewing upload batch" do
    batch = UploadBatch.create!(owner: @owner)
    photo = create_uploaded_photo(batch)

    patch commit_upload_batch_path(batch)

    assert_redirected_to uploads_path
    assert_equal "committed", batch.reload.status
    assert_not_nil batch.committed_at
    assert_equal batch, photo.reload.upload_batch
  end

  test "owner can undo a reviewing upload batch" do
    batch = UploadBatch.create!(owner: @owner)
    photo = create_uploaded_photo(batch)

    assert_difference "Photo.count", -1 do
      delete rollback_upload_batch_path(batch)
    end

    assert_redirected_to uploads_path
    assert_equal "rolled_back", batch.reload.status
    assert_not_nil batch.rolled_back_at
    assert_raises(ActiveRecord::RecordNotFound) { photo.reload }
  end

  test "owner cannot manage another owner's upload batch" do
    other = users(:two)
    batch = UploadBatch.create!(owner: other)

    patch commit_upload_batch_path(batch)

    assert_response :not_found
  end

  private

  def create_uploaded_photo(batch)
    photo = @owner.photos.new(upload_batch: batch)
    photo.original.attach(Rack::Test::UploadedFile.new(Rails.root.join("public/icon.png"), "image/png"))
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
