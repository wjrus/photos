require "test_helper"

class MobileApiTest < ActionDispatch::IntegrationTest
  setup do
    @owner = users(:one)
    @device, @credentials = DeviceSession.issue!(user: @owner, name: "Synthetic phone", platform: "ios")
    @headers = { "Authorization" => "Bearer #{@credentials[:access_token]}" }
  end

  test "capabilities are public but browser sessions do not authenticate the API" do
    get "/api/v1/capabilities"
    assert_response :success
    assert_equal "1", json["api_version"]
    assert_equal PhotoBulkOperation::ACTIONS, json.dig("features", "bulk_actions")
    get "/api/v1/photos"
    assert_response :unauthorized
    assert_equal "unauthorized", json.dig("error", "code")
    assert_equal "private, no-store", response.headers["Cache-Control"]
  end

  test "password login issues only hashed device secrets with rotation and revocation" do
    @owner.update!(password: "synthetic-password", password_confirmation: "synthetic-password")
    post "/api/v1/session", params: { email: @owner.email, password: "wrong", device_name: "Test", platform: "ios" }, as: :json
    assert_response :unauthorized
    post "/api/v1/session", params: { email: @owner.email, password: "synthetic-password", device_name: "Test", platform: "ios" }, as: :json
    assert_response :created
    credentials = json
    device = DeviceSession.find(credentials["device_id"])
    assert_equal User.digest(credentials["access_token"]), device.token_digest
    assert_not_equal credentials["access_token"], device.token_digest
    post "/api/v1/session/refresh", params: { refresh_token: credentials["refresh_token"] }, as: :json
    assert_response :success
    rotated = json
    assert_nil DeviceSession.authenticate(credentials["access_token"])
    post "/api/v1/session/refresh", params: { refresh_token: credentials["refresh_token"] }, as: :json
    assert_response :unauthorized
    delete "/api/v1/session", headers: { "Authorization" => "Bearer #{rotated['access_token']}" }
    assert_response :no_content
    assert_nil DeviceSession.authenticate(rotated["access_token"])
    post "/api/v1/session/refresh", params: { refresh_token: rotated["refresh_token"] }, as: :json
    assert_response :unauthorized
  end

  test "password changes expiry and cross-account device management are enforced" do
    get "/api/v1/devices", headers: @headers
    assert_response :success
    assert json["devices"].first["current"]
    assert_not response.body.include?(@device.token_digest)
    other, = DeviceSession.issue!(user: users(:two), name: "Other", platform: "android")
    delete "/api/v1/devices/#{other.id}", headers: @headers
    assert_response :not_found
    @device.update!(expires_at: 1.minute.ago)
    get "/api/v1/me", headers: @headers
    assert_response :unauthorized
    post "/api/v1/session/refresh", params: { refresh_token: @credentials[:refresh_token] }, as: :json
    assert_response :success
    token = json["access_token"]
    @owner.update!(password: "changed-synthetic-password", password_confirmation: "changed-synthetic-password")
    get "/api/v1/me", headers: { "Authorization" => "Bearer #{token}" }
    assert_response :unauthorized
  end

  test "deterministic pagination and swiping retain album search and media context" do
    early = photo(title: "Early", captured_at: Time.utc(2026, 1, 1))
    late = photo(title: "Late", captured_at: Time.utc(2026, 2, 1))
    undated = photo(title: "Undated")
    get "/api/v1/photos", params: { limit: 1 }, headers: @headers
    assert_response :success
    assert_equal [ late.id ], json["photos"].pluck("id")
    cursor = json["next_cursor"]
    get "/api/v1/photos", params: { limit: 1, cursor: cursor }, headers: @headers
    assert_equal [ early.id ], json["photos"].pluck("id")
    get "/api/v1/photos", params: { limit: 1, cursor: early.stream_cursor, direction: "previous" }, headers: @headers
    assert_equal [ late.id ], json["photos"].pluck("id")
    get "/api/v1/photos/#{early.id}/navigation", headers: @headers
    assert_equal late.id, json.dig("previous", "id")
    assert_equal undated.id, json.dig("next", "id")
    album = @owner.photo_albums.create!(title: "Synthetic album", source: "manual")
    album.photos << [ early, late ]
    get "/api/v1/photos", params: { album_id: album.id }, headers: @headers
    assert_equal [ early.id, late.id ], json["photos"].pluck("id")
    get "/api/v1/photos/#{early.id}/navigation", params: { album_id: album.id }, headers: @headers
    assert_nil json["previous"]
    assert_equal late.id, json.dig("next", "id")
    get "/api/v1/photos/#{early.id}/navigation", params: { q: "Early" }, headers: @headers
    assert_nil json["previous"]
    assert_nil json["next"]
    get "/api/v1/photos", params: { cursor: "malformed" }, headers: @headers
    assert_response :bad_request
    get "/api/v1/photos/timeline", headers: @headers
    assert_response :success
    assert_includes json["periods"].pluck("month"), "2026-01"
  end

  test "viewers only see public tagged or shared photos and cannot edit or download originals" do
    public_photo = photo(visibility: "public")
    private_photo = photo
    tagged_photo = photo
    shared_photo = photo
    viewer = users(:two)
    tagged_photo.photo_people_tags.create!(user: viewer, tagged_by: @owner)
    album = @owner.photo_albums.create!(title: "Shared", source: "manual")
    album.photos << shared_photo
    album.photo_album_shares.create!(user: viewer, shared_by: @owner)
    _device, credentials = DeviceSession.issue!(user: viewer, name: "Viewer", platform: "ios")
    headers = { "Authorization" => "Bearer #{credentials[:access_token]}" }
    get "/api/v1/photos", headers: headers
    assert_response :success
    assert_equal [ public_photo.id, tagged_photo.id, shared_photo.id ].sort, json["photos"].pluck("id").sort
    get "/api/v1/photos/#{private_photo.id}", headers: headers
    assert_response :not_found
    get "/api/v1/photos/#{public_photo.id}/media/original", headers: headers
    assert_response :forbidden
    post "/api/v1/photos/bulk", params: { bulk_action: "archive", photo_ids: [ public_photo.id ] }, headers: headers, as: :json
    assert_response :forbidden
    post "/api/v1/uploads", headers: headers, as: :json
    assert_response :forbidden
    get "/api/v1/photos/#{shared_photo.id}/info", headers: headers
    assert_response :success
    assert_nil json["location"]
    get "/api/v1/photos", params: { collection: "archive" }, headers: headers
    assert_response :not_found
  end

  test "info and maps expose curated metadata only to trusted users" do
    item = photo(visibility: "public")
    item.create_metadata!(latitude: 10, longitude: 20, camera_model: "Synthetic camera", raw: { "private_path" => "/synthetic/internal" })
    get "/api/v1/photos/#{item.id}/info", headers: @headers
    assert_response :success
    assert_equal 10.0, json.dig("location", "latitude")
    assert_equal "Synthetic camera", json.dig("metadata", "camera_model")
    assert_not response.body.include?("private_path")
    get "/api/v1/map", params: { north: 11, south: 9, east: 21, west: 19 }, headers: @headers
    assert_response :success
    assert_equal item.id, json["markers"].sole.dig("photo", "id")
    get "/api/v1/map", params: { north: 91 }, headers: @headers
    assert_response :bad_request
    get "/api/v1/locations", headers: @headers
    assert_response :success
    assert_equal 1, json["locations"].sole["photo_count"]
    viewer = users(:two)
    viewer.update!(invited_at: nil, invite_accepted_at: nil)
    _device, credentials = DeviceSession.issue!(user: viewer, name: "Untrusted", platform: "other")
    get "/api/v1/photos/#{item.id}/info", headers: { "Authorization" => "Bearer #{credentials[:access_token]}" }
    assert_response :forbidden
  end

  test "locked photos require a separate device unlock and media links recheck it" do
    previous = ENV["PHOTOS_LOCKED_FOLDER_PASSWORD"]
    ENV["PHOTOS_LOCKED_FOLDER_PASSWORD"] = "synthetic-lock-password"
    item = photo(restricted: true)
    get "/api/v1/photos/#{item.id}", params: { collection: "restricted" }, headers: @headers
    assert_response :not_found
    post "/api/v1/restricted_access", params: { password: "synthetic-lock-password" }, headers: @headers, as: :json
    assert_response :success
    get "/api/v1/photos/#{item.id}/info", params: { collection: "restricted" }, headers: @headers
    assert_response :success
    post "/api/v1/photos/#{item.id}/media_url", params: { collection: "restricted", variant: "original" }, headers: @headers, as: :json
    assert_response :success
    url = json["url"]
    post "/api/v1/photos/bulk", params: { bulk_action: "unrestrict", photo_ids: [ item.id ] }, headers: @headers, as: :json
    assert_response :success
    assert_not_predicate item.reload, :restricted?
    item.restrict!
    delete "/api/v1/restricted_access", headers: @headers
    get url
    assert_response :not_found
    post "/api/v1/photos/bulk", params: { bulk_action: "unrestrict", photo_ids: [ item.id ] }, headers: @headers, as: :json
    assert_response :not_found
  ensure
    ENV["PHOTOS_LOCKED_FOLDER_PASSWORD"] = previous
  end

  test "media grants are scoped expire revoke and support video range requests" do
    item = photo
    post "/api/v1/photos/#{item.id}/media_url", params: { variant: "original" }, headers: @headers, as: :json
    assert_response :success
    url = json["url"]
    get url, headers: { "Range" => "bytes=0-9" }
    assert_response :partial_content
    assert_equal File.binread(Rails.root.join("public/icon.png"))[0, 10], response.body
    assert_equal "bytes 0-9/#{item.byte_size}", response.headers["Content-Range"]
    head url
    assert_response :success
    assert_empty response.body
    assert_equal item.byte_size.to_s, response.headers["Content-Length"]
    get url.sub("/original?", "/display?")
    assert_response :unauthorized
    post "/api/v1/photos/#{item.id}/media_url", params: { variant: "original", expires_in: 3601 }, headers: @headers, as: :json
    assert_response :bad_request
    get "/api/v1/photos/#{item.id}/media/original", headers: @headers.merge("Range" => "bytes=999999999-")
    assert_response :range_not_satisfiable
    travel 11.minutes do
      get url
      assert_response :unauthorized
    end
    @device.revoke!
    get url
    assert_response :unauthorized
  end

  test "album membership bulk operations and archive restore are atomic and owner scoped" do
    first = photo
    second = photo
    post "/api/v1/albums", params: { album: { title: "Synthetic trip" } }, headers: @headers, as: :json
    assert_response :created
    album_id = json.dig("album", "id")
    post "/api/v1/albums/#{album_id}/photos", params: { photo_ids: [ first.id, second.id ] }, headers: @headers, as: :json
    assert_response :success
    assert_equal 2, json["affected_count"]
    put "/api/v1/albums/#{album_id}/cover", params: { photo_ids: [ first.id ] }, headers: @headers, as: :json
    assert_response :success
    assert_equal first.id, PhotoAlbum.find(album_id).cover_photo_id
    delete "/api/v1/albums/#{album_id}/photos", params: { photo_ids: [ first.id ] }, headers: @headers, as: :json
    assert_response :success
    assert_equal second.id, PhotoAlbum.find(album_id).cover_photo_id
    post "/api/v1/photos/bulk", params: { bulk_action: "archive", photo_ids: [ first.id, second.id ] }, headers: @headers, as: :json
    assert_response :success
    get "/api/v1/photos", params: { collection: "archive" }, headers: @headers
    assert_equal 2, json["photos"].size
    post "/api/v1/photos/bulk", params: { bulk_action: "restore", photo_ids: [ first.id, second.id ] }, headers: @headers, as: :json
    assert_response :success
    other = photo(owner: users(:two))
    post "/api/v1/photos/bulk", params: { bulk_action: "delete", photo_ids: [ first.id, other.id ] }, headers: @headers, as: :json
    assert_response :not_found
    assert Photo.exists?(first.id)
    post "/api/v1/photos/bulk", params: { bulk_action: "add_to_photo_book", new_photo_book_title: "Synthetic book", photo_ids: [ first.id ] }, headers: @headers, as: :json
    assert_response :success
    assert_equal 1, json["affected_count"]
    post "/api/v1/albums/bulk", params: { bulk_action: "publish", album_ids: [ album_id ] }, headers: @headers, as: :json
    assert_response :success
    assert_predicate PhotoAlbum.find(album_id), :public?
  end

  test "invalid manifests and missing upload authentication return JSON errors" do
    post "/api/v1/uploads", params: { upload: { client_asset_id: "asset", filename: "../bad.jpg", content_type: "image/jpeg", byte_size: 1, checksum_sha256: "a" * 64 } }, headers: @headers, as: :json
    assert_response :unprocessable_content
    post "/api/v1/uploads", params: { upload: { client_asset_id: "asset", byte_size: "bad" } }, headers: @headers, as: :json
    assert_response :bad_request
    post "/api/v1/uploads", params: { upload: manifest }, as: :json
    assert_response :unauthorized
    post "/api/v1/uploads", params: "{invalid", headers: @headers.merge("Content-Type" => "application/json")
    assert_response :bad_request
    assert_equal "invalid_request", json.dig("error", "code")
  end

  test "raw background upload completion verifies checksum is idempotent and deduplicates devices" do
    post "/api/v1/uploads", params: { upload: manifest }, headers: @headers, as: :json
    assert_response :created
    upload_id = json.dig("upload", "id")
    post "/api/v1/uploads", params: { upload: manifest }, headers: @headers, as: :json
    assert_response :success
    assert_equal upload_id, json.dig("upload", "id")
    post "/api/v1/uploads", params: { upload: manifest.merge(filename: "changed.png") }, headers: @headers, as: :json
    assert_response :conflict
    put "/api/v1/uploads/#{upload_id}/file?complete=false", params: image_bytes, headers: @headers.merge("Content-Type" => "application/octet-stream")
    assert_response :success
    assert_equal [ 0 ], json.dig("upload", "received_chunks")
    assert_difference "Photo.count", 1 do
      post "/api/v1/uploads/#{upload_id}/complete", headers: @headers, as: :json
      assert_response :success
    end
    photo_id = json.dig("upload", "photo", "id")
    assert_equal image_bytes, Photo.find(photo_id).original.download
    assert_predicate Photo.find(photo_id), :private?
    assert_no_difference "Photo.count" do
      post "/api/v1/uploads/#{upload_id}/complete", headers: @headers, as: :json
      assert_response :success
    end
    assert_equal photo_id, json.dig("upload", "photo", "id")
    second_device, second_credentials = DeviceSession.issue!(user: @owner, name: "Second phone", platform: "ios")
    second_headers = { "Authorization" => "Bearer #{second_credentials[:access_token]}" }
    get "/api/v1/uploads/#{upload_id}", headers: second_headers
    assert_response :not_found
    post "/api/v1/uploads", params: { upload: manifest }, headers: second_headers, as: :json
    assert_response :created
    second_id = json.dig("upload", "id")
    put "/api/v1/uploads/#{second_id}/chunks/0", params: image_bytes, headers: second_headers.merge("Content-Type" => "application/octet-stream")
    assert_response :success
    assert_no_difference "Photo.count" do
      post "/api/v1/uploads/#{second_id}/complete", headers: second_headers, as: :json
      assert_response :success
    end
    assert json.dig("upload", "duplicate")
    assert_equal photo_id, json.dig("upload", "photo", "id")
    assert_equal 0, second_device.mobile_uploads.find(second_id).mobile_upload_chunks.count
  end

  test "chunks retry replace data reject wrong sizes and reject corrupted completion" do
    post "/api/v1/uploads", params: { upload: manifest.merge(checksum_sha256: "a" * 64) }, headers: @headers, as: :json
    id = json.dig("upload", "id")
    post "/api/v1/uploads/#{id}/complete", headers: @headers, as: :json
    assert_response :bad_request
    put "/api/v1/uploads/#{id}/chunks/0", params: "short", headers: @headers.merge("Content-Type" => "application/octet-stream")
    assert_response :bad_request
    2.times do
      put "/api/v1/uploads/#{id}/chunks/0", params: image_bytes, headers: @headers.merge("Content-Type" => "application/octet-stream")
      assert_response :success
    end
    assert_equal 1, MobileUpload.find(id).mobile_upload_chunks.count
    assert_no_difference "Photo.count" do
      post "/api/v1/uploads/#{id}/complete", headers: @headers, as: :json
      assert_response :bad_request
    end
    MobileUpload.find(id).update!(expires_at: 1.minute.ago)
    put "/api/v1/uploads/#{id}/chunks/0", params: image_bytes, headers: @headers.merge("Content-Type" => "application/octet-stream")
    assert_response :conflict
    assert_difference "MobileUpload.count", -1 do
      CleanupMobileUploadsJob.perform_now
    end
  end

  test "raw file upload finalizes automatically and survives repeated background requests" do
    post "/api/v1/uploads", params: { upload: manifest }, headers: @headers, as: :json
    id = json.dig("upload", "id")
    assert_difference "Photo.count", 1 do
      put "/api/v1/uploads/#{id}/file", params: image_bytes, headers: @headers.merge("Content-Type" => "application/octet-stream")
      assert_response :success
    end
    photo_id = json.dig("upload", "photo", "id")
    assert json.dig("upload", "completed_at")
    assert_no_difference "Photo.count" do
      put "/api/v1/uploads/#{id}/file", params: image_bytes, headers: @headers.merge("Content-Type" => "application/octet-stream")
      assert_response :success
    end
    assert_equal photo_id, json.dig("upload", "photo", "id")
  end

  test "media links recheck sharing permissions and video playback supports suffix ranges" do
    viewer = users(:two)
    item = photo
    tag = item.photo_people_tags.create!(user: viewer, tagged_by: @owner)
    _device, credentials = DeviceSession.issue!(user: viewer, name: "Viewer", platform: "ios")
    headers = { "Authorization" => "Bearer #{credentials[:access_token]}" }
    post "/api/v1/photos/#{item.id}/media_url", params: { variant: "display" }, headers: headers, as: :json
    assert_response :success
    url = json["url"]
    get url
    assert_response :success
    assert_equal "image/jpeg", response.media_type
    tag.destroy!
    get url
    assert_response :not_found
    video = @owner.photos.create!(original: { io: StringIO.new("synthetic video"), filename: "synthetic.mov", content_type: "video/quicktime" })
    get "/api/v1/photos/#{video.id}/media/video", headers: @headers
    assert_response :conflict
    video.video_display.attach(io: StringIO.new("synthetic playable video"), filename: "synthetic.mp4", content_type: "video/mp4")
    get "/api/v1/photos/#{video.id}/media/video", headers: @headers.merge("Range" => "bytes=-5")
    assert_response :partial_content
    assert_equal "video", response.body
  end

  test "all state actions photo edits tags and album deletion preserve originals and privacy" do
    item = photo
    %w[publish unpublish archive restore restrict].each do |operation|
      post "/api/v1/photos/bulk", params: { bulk_action: operation, photo_ids: [ item.id ] }, headers: @headers, as: :json
      assert_response :success
    end
    assert_predicate item.reload, :restricted?
    item.unrestrict!
    patch "/api/v1/photos/#{item.id}", params: { photo: { title: "Updated", description: "Synthetic caption" } }, headers: @headers, as: :json
    assert_response :success
    assert_equal "Synthetic caption", item.reload.description
    post "/api/v1/photos/#{item.id}/people_tags", params: { user_id: users(:two).id }, headers: @headers, as: :json
    assert_response :created
    tag_id = json.dig("tag", "id")
    delete "/api/v1/photos/#{item.id}/people_tags/#{tag_id}", headers: @headers
    assert_response :no_content
    post "/api/v1/photos/bulk", params: { bulk_action: "set_location", location_address: "", photo_ids: [ item.id ] }, headers: @headers, as: :json
    assert_response :unprocessable_content
    post "/api/v1/photos/bulk", params: { bulk_action: "add_to_album", new_album_title: "New synthetic album", photo_ids: [ item.id ] }, headers: @headers, as: :json
    assert_response :success
    album_id = json["album_id"]
    get "/api/v1/albums", headers: @headers
    assert_response :success
    assert_equal item.id, json["albums"].sole.dig("cover", "id")
    post "/api/v1/albums/bulk", params: { bulk_action: "delete", album_ids: [ album_id ] }, headers: @headers, as: :json
    assert_response :success
    assert Photo.exists?(item.id)
    delete "/api/v1/photos/#{item.id}", headers: @headers
    assert_response :no_content
    assert_not Photo.exists?(item.id)
  end

  test "expired sessions and malformed or oversized selections cannot access or mutate data" do
    @device.update!(refresh_expires_at: 1.minute.ago)
    post "/api/v1/session/refresh", params: { refresh_token: @credentials[:refresh_token] }, as: :json
    assert_response :unauthorized
    @device.update!(refresh_expires_at: 1.day.from_now)
    get "/api/v1/photos", params: { cursor: [ "bad" ] }, headers: @headers
    assert_response :bad_request
    get "/api/v1/photos", params: { captured_before: [ "bad" ] }, headers: @headers
    assert_response :bad_request
    post "/api/v1/photos/bulk", params: { bulk_action: "delete", photo_ids: (1..201).to_a }, headers: @headers, as: :json
    assert_response :bad_request
  end

  test "multiple chunks enforce position and last chunk size then preserve complete video bytes" do
    bytes = "v" * MobileUpload::CHUNK_BYTES + "tail"
    upload_manifest = { client_asset_id: "synthetic-multichunk", filename: "synthetic.mov", content_type: "video/quicktime",
      byte_size: bytes.bytesize, checksum_sha256: Digest::SHA256.hexdigest(bytes) }
    post "/api/v1/uploads", params: { upload: upload_manifest }, headers: @headers, as: :json
    assert_response :created
    id = json.dig("upload", "id")
    assert_equal 2, json.dig("upload", "chunk_count")
    put "/api/v1/uploads/#{id}/chunks/2", params: "tail", headers: @headers.merge("Content-Type" => "application/octet-stream")
    assert_response :bad_request
    put "/api/v1/uploads/#{id}/chunks/1", params: "tail", headers: @headers.merge("Content-Type" => "application/octet-stream")
    assert_response :success
    post "/api/v1/uploads/#{id}/complete", headers: @headers, as: :json
    assert_response :bad_request
    put "/api/v1/uploads/#{id}/chunks/0", params: bytes[0, MobileUpload::CHUNK_BYTES], headers: @headers.merge("Content-Type" => "application/octet-stream")
    assert_response :success
    post "/api/v1/uploads/#{id}/complete", headers: @headers, as: :json
    assert_response :success
    assert_equal bytes, MobileUpload.find(id).photo.original.download
    assert_predicate MobileUpload.find(id).photo, :video?
  end

  test "manifest retries normalize capture time to database precision" do
    body = manifest.merge(captured_at: "2026-10-04T12:00:00.123456789Z")
    post "/api/v1/uploads", params: { upload: body }, headers: @headers, as: :json
    assert_response :created
    id = json.dig("upload", "id")
    post "/api/v1/uploads", params: { upload: body }, headers: @headers, as: :json
    assert_response :success
    assert_equal id, json.dig("upload", "id")
  end

  private

  def json
    response.parsed_body
  end

  def photo(owner: @owner, **attributes)
    owner.photos.create!(attributes.merge(original: { io: StringIO.new(image_bytes), filename: "synthetic.png", content_type: "image/png" }))
  end

  def image_bytes
    File.binread(Rails.root.join("public/icon.png"))
  end

  def manifest
    { client_asset_id: "synthetic-asset", filename: "synthetic.png", content_type: "image/png", byte_size: image_bytes.bytesize,
      checksum_sha256: Digest::SHA256.hexdigest(image_bytes) }
  end
end
