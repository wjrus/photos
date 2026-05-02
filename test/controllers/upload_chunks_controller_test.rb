require "test_helper"

class UploadChunksControllerTest < ActionDispatch::IntegrationTest
  setup do
    OmniAuth.config.test_mode = true
    @owner = users(:one)
    sign_in_as(@owner)
  end

  teardown do
    FileUtils.rm_rf(resumable_upload_root)
    OmniAuth.config.mock_auth[:google_oauth2] = nil
    OmniAuth.config.test_mode = false
  end

  test "owner can upload chunks and complete a batch" do
    upload_id = SecureRandom.uuid

    post upload_chunks_path, params: chunk_params(upload_id, "file-0", 0, "IMG_E0073.HEIC", "image/heic", "fake heic bytes")
    assert_response :success

    post upload_chunks_path, params: chunk_params(upload_id, "file-1", 0, "IMG_O0073.AAE", "application/xml", "<?xml version=\"1.0\"?>")
    assert_response :success

    assert_difference "Photo.count", 1 do
      post complete_upload_chunks_path,
        params: {
          upload_id: upload_id,
          files: [
            {
              file_id: "file-0",
              filename: "IMG_E0073.HEIC",
              content_type: "image/heic",
              byte_size: 15,
              total_chunks: 1
            },
            {
              file_id: "file-1",
              filename: "IMG_O0073.AAE",
              content_type: "application/xml",
              byte_size: 21,
              total_chunks: 1
            }
          ]
        },
        as: :json
    end

    photo = Photo.find_by!(original_filename: "IMG_E0073.HEIC")
    assert_response :success
    assert_equal 1, photo.sidecar_count
    assert_equal "private", photo.visibility
    assert_equal uploads_path, response.parsed_body.fetch("redirect_url")
    assert_not Dir.exist?(resumable_upload_root.join(@owner.id.to_s, upload_id))
  end

  test "owner can check uploaded chunk status" do
    upload_id = SecureRandom.uuid
    post upload_chunks_path, params: chunk_params(upload_id, "file-0", 0, "clip.mov", "video/quicktime", "first")
    assert_response :success

    post status_upload_chunks_path,
      params: {
        upload_id: upload_id,
        files: [
          {
            file_id: "file-0",
            filename: "clip.mov",
            content_type: "video/quicktime",
            byte_size: 10,
            total_chunks: 2
          }
        ]
      },
      as: :json

    assert_response :success
    assert_equal [ 0 ], response.parsed_body.dig("files", "file-0")
  end

  test "stale upload directories are cleaned up" do
    stale_upload = resumable_upload_root.join(@owner.id.to_s, "stale")
    FileUtils.mkdir_p(stale_upload)
    FileUtils.touch(stale_upload, mtime: 2.hours.ago.to_time)

    post upload_chunks_path, params: chunk_params(SecureRandom.uuid, "file-0", 0, "photo.jpg", "image/jpeg", "jpg")

    assert_response :success
    assert_not Dir.exist?(stale_upload)
  end

  test "trusted non owner cannot upload chunks" do
    delete sign_out_path
    sign_in_as(users(:two))

    post upload_chunks_path, params: chunk_params(SecureRandom.uuid, "file-0", 0, "photo.jpg", "image/jpeg", "jpg")

    assert_response :forbidden
  end

  private

  def chunk_params(upload_id, file_id, chunk_index, filename, content_type, body)
    {
      upload_id: upload_id,
      file_id: file_id,
      chunk_index: chunk_index,
      chunk: Rack::Test::UploadedFile.new(StringIO.new(body), content_type, original_filename: filename)
    }
  end

  def resumable_upload_root
    Rails.root.join("tmp/resumable_uploads", "test-#{Process.pid}")
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
