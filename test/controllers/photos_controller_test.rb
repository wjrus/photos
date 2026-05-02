require "test_helper"

class PhotosControllerTest < ActionDispatch::IntegrationTest
  setup do
    OmniAuth.config.test_mode = true
    @owner = users(:one)
    @trusted_viewer_emails = ENV["PHOTOS_TRUSTED_VIEWER_EMAILS"]
    @google_maps_api_key = ENV["GOOGLE_MAPS_EMBED_API_KEY"]
    ENV["GOOGLE_MAPS_EMBED_API_KEY"] = "test-google-maps-key"
    sign_in_as(@owner)
  end

  teardown do
    ENV["PHOTOS_TRUSTED_VIEWER_EMAILS"] = @trusted_viewer_emails
    ENV["GOOGLE_MAPS_EMBED_API_KEY"] = @google_maps_api_key
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

  test "owner upload can return to upload page" do
    assert_difference "Photo.count", 1 do
      post photos_path, params: {
        return_to: uploads_path,
        photo: {
          title: "Upload page import",
          original: fixture_upload("public/icon.png", "image/png")
        }
      }
    end

    assert_redirected_to uploads_path
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

  test "owner batch uploads media files and pairs aae sidecars by basename" do
    assert_difference "Photo.count", 2 do
      post photos_path, params: {
        photos: {
          files: [
            Rack::Test::UploadedFile.new(StringIO.new("fake heic bytes"), "image/heic", original_filename: "IMG_0001.HEIC"),
            Rack::Test::UploadedFile.new(StringIO.new("<?xml version=\"1.0\"?>"), "application/xml", original_filename: "IMG_0001.AAE"),
            Rack::Test::UploadedFile.new(StringIO.new("fake mp4 bytes"), "video/mp4", original_filename: "IMG_0002.MP4")
          ]
        }
      }
    end

    heic = Photo.find_by!(original_filename: "IMG_0001.HEIC")
    mp4 = Photo.find_by!(original_filename: "IMG_0002.MP4")
    assert_redirected_to root_path
    assert_equal 1, heic.sidecar_count
    assert_equal 0, mp4.sidecar_count
    assert_equal "private", heic.visibility
    assert_equal "private", mp4.visibility
  end

  test "owner batch upload pairs apple edited aae sidecar with edited heic original" do
    assert_difference "Photo.count", 1 do
      post photos_path, params: {
        photos: {
          files: [
            Rack::Test::UploadedFile.new(StringIO.new("fake heic bytes"), "image/heic", original_filename: "IMG_E0073.HEIC"),
            Rack::Test::UploadedFile.new(StringIO.new("<?xml version=\"1.0\"?>"), "application/xml", original_filename: "IMG_O0073.AAE")
          ]
        }
      }
    end

    photo = Photo.find_by!(original_filename: "IMG_E0073.HEIC")
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

  test "owner can publish and stay on the photo detail" do
    photo = attached_photo

    patch publish_photo_path(photo), params: { return_to: photo_path(photo) }

    assert_redirected_to photo_path(photo)
    assert_predicate photo.reload, :public?
  end

  test "visibility return path ignores external urls" do
    photo = attached_photo

    patch publish_photo_path(photo), params: { return_to: "https://example.com/nope" }

    assert_redirected_to root_path
    assert_predicate photo.reload, :public?
  end

  test "owner can save an optional caption" do
    photo = attached_photo

    patch caption_photo_path(photo), params: { return_to: map_path, photo: { description: "A quiet lake before dinner." } }

    assert_redirected_to photo_path(photo, return_to: map_path)
    assert_equal "A quiet lake before dinner.", photo.reload.description
  end

  test "owner can destroy a photo" do
    photo = attached_photo

    assert_difference "Photo.count", -1 do
      delete photo_path(photo)
    end

    assert_redirected_to root_path
    assert_raises(ActiveRecord::RecordNotFound) { photo.reload }
  end

  test "non owner cannot destroy a photo" do
    photo = attached_photo
    delete sign_out_path
    sign_in_as(users(:two))

    assert_no_difference "Photo.count" do
      delete photo_path(photo)
    end

    assert_redirected_to root_path
  end

  test "owner can retry failed drive archive" do
    photo = attached_photo
    photo.create_drive_archive_object!(status: "failed", error: "Drive API disabled")

    assert_enqueued_with(job: MirrorOriginalToDriveJob) do
      post retry_archive_photo_path(photo), params: { return_to: map_path }
    end

    assert_redirected_to photo_path(photo, return_to: map_path)
    archive_object = photo.reload.drive_archive_object
    assert_equal "pending", archive_object.status
    assert_nil archive_object.error
  end

  test "owner can retry all failed drive archives" do
    failed_photo = attached_photo(title: "Failed one")
    failed_photo.create_drive_archive_object!(status: "failed", error: "Drive API disabled")
    another_failed_photo = attached_photo(title: "Failed two")
    another_failed_photo.create_drive_archive_object!(status: "failed", error: "Token expired")
    archived_photo = attached_photo(title: "Archived")
    archived_photo.create_drive_archive_object!(status: "archived")

    assert_enqueued_jobs 2, only: MirrorOriginalToDriveJob do
      post retry_failed_archives_photos_path
    end

    assert_redirected_to root_path
    assert_equal "pending", failed_photo.reload.drive_archive_object.status
    assert_nil failed_photo.drive_archive_object.error
    assert_equal "pending", another_failed_photo.reload.drive_archive_object.status
    assert_nil another_failed_photo.drive_archive_object.error
    assert_equal "archived", archived_photo.reload.drive_archive_object.status
  end

  test "owner sees archive and metadata details" do
    photo = attached_photo
    photo.create_metadata!(
      extraction_status: "complete",
      camera_make: "Fuji",
      camera_model: "X100",
      width: 3024,
      height: 4032,
      latitude: 44.762222,
      longitude: -85.597983,
      raw: {}
    )

    get photo_path(photo)

    assert_response :success
    assert_includes response.body, "Archive"
    assert_select "section[data-controller='info-panel']"
    assert_select "aside#photo-info-panel a", { text: "Back to stream", count: 0 }
    assert_select "button[aria-label='Show photo information'][data-action='info-panel#toggle']"
    assert_select "button[aria-label='Close photo information'][data-action='info-panel#close']"
    assert_select "aside#photo-info-panel.translate-x-full"
    assert_includes response.body, "Fuji X100"
    assert_includes response.body, "3,024 x 4,032"
    assert_includes response.body, "Photo location map"
    assert_includes response.body, "google.com/maps/embed/v1/place"
    assert_includes response.body, photo.original_filename
    assert_includes response.body, "Download original"
    assert_includes response.body, "Remove photo?"
    assert_select "[data-controller='confirm-modal']"
    assert_select "[data-turbo-confirm]", false
  end

  test "owner sees location unavailable when metadata has no gps" do
    photo = attached_photo
    photo.create_metadata!(extraction_status: "complete", camera_make: "Fuji", camera_model: "X100", raw: {})

    get photo_path(photo)

    assert_response :success
    assert_includes response.body, "Location"
    assert_includes response.body, "Unavailable"
    refute_includes response.body, "Photo location map"
  end

  test "owner can access original media" do
    photo = attached_photo

    get media_photo_path(photo)

    assert_response :success
    assert_equal "image/png", response.media_type
  end

  test "detail view exposes stream neighbors for keyboard and swipe navigation" do
    newer = attached_photo(title: "Newer")
    photo = attached_photo(title: "Current")
    older = attached_photo(title: "Older")
    newer.update_columns(created_at: Time.zone.local(2026, 1, 3), updated_at: Time.zone.local(2026, 1, 3))
    photo.update_columns(created_at: Time.zone.local(2026, 1, 2), updated_at: Time.zone.local(2026, 1, 2))
    older.update_columns(created_at: Time.zone.local(2026, 1, 1), updated_at: Time.zone.local(2026, 1, 1))

    get photo_path(photo, return_to: map_path)

    assert_response :success
    assert_select "main[data-controller='stream-navigation']"
    assert_select "a[href='#{photo_path(newer, return_to: map_path)}'][data-turbo-action='replace']", text: "Up"
    assert_select "a[href='#{photo_path(older, return_to: map_path)}'][data-turbo-action='replace']", text: "Down"
    assert_includes response.body, %(data-stream-navigation-back-url-value="#{map_path}")
    assert_includes response.body, %(data-stream-navigation-previous-url-value="#{photo_path(newer, return_to: map_path)}")
    assert_includes response.body, %(data-stream-navigation-next-url-value="#{photo_path(older, return_to: map_path)}")
  end

  test "photo stream renders an infinite scroll sentinel when more photos exist" do
    (Photo::STREAM_PAGE_SIZE + 1).times do |index|
      photo = attached_photo(title: "Stream #{index}")
      photo.update_columns(created_at: index.minutes.ago, updated_at: index.minutes.ago)
    end

    get root_path

    assert_response :success
    assert_select "[data-controller='infinite-scroll']"
    assert_select "[data-infinite-scroll-target='sentinel']"
  end

  test "public viewer sees public display without privileged metadata" do
    photo = attached_photo
    photo.update!(description: "Private travel note.")
    photo.create_metadata!(extraction_status: "complete", camera_make: "Fuji", camera_model: "X100", raw: {})
    photo.publish!
    delete sign_out_path

    get photo_path(photo)

    assert_response :success
    assert_includes response.body, photo.title
    refute_includes response.body, "Private travel note."
    refute_includes response.body, "Caption"
    refute_includes response.body, "Archive"
    refute_includes response.body, "Fuji X100"
    refute_includes response.body, "Photo location map"
    refute_includes response.body, photo.original_filename
    refute_includes response.body, "Download original"
  end

  test "trusted signed-in viewer sees public photo location without archive access" do
    ENV["PHOTOS_TRUSTED_VIEWER_EMAILS"] = users(:two).email
    photo = attached_photo
    photo.update!(description: "Met everyone by the river.")
    photo.create_metadata!(
      extraction_status: "complete",
      camera_make: "Fuji",
      camera_model: "X100",
      latitude: 44.762222,
      longitude: -85.597983,
      raw: {}
    )
    photo.publish!
    delete sign_out_path
    sign_in_as(users(:two))

    get photo_path(photo)

    assert_response :success
    assert_includes response.body, "Met everyone by the river."
    assert_includes response.body, "Fuji X100"
    assert_includes response.body, "Photo location map"
    assert_includes response.body, "google.com/maps/embed/v1/place"
    assert_includes response.body, "Open map"
    refute_includes response.body, "Archive"
    refute_includes response.body, photo.original_filename
    refute_includes response.body, "Download original"
  end

  test "public viewer cannot access original media for public photos" do
    photo = attached_photo
    photo.publish!
    delete sign_out_path

    get media_photo_path(photo)

    assert_redirected_to root_path
  end

  test "owner video detail renders the original video player" do
    photo = attached_video

    get photo_path(photo)

    assert_response :success
    assert_includes response.body, "<video"
    assert_includes response.body, "controls"
    assert_includes response.body, photo.original_filename
  end

  test "public video detail withholds original playback" do
    photo = attached_video
    photo.publish!
    delete sign_out_path

    get photo_path(photo)

    assert_response :success
    refute_includes response.body, "<video"
    assert_includes response.body, "Video derivative unavailable."
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

  def attached_photo(title: nil)
    photo = @owner.photos.new
    photo.title = title if title
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
