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
    assert_equal @owner.upload_batches.reviewing.sole, photo.upload_batch
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
    assert_equal heic.upload_batch, mp4.upload_batch
    assert_equal @owner.upload_batches.reviewing.sole, heic.upload_batch
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

    assert_redirected_to photo_path(photo)
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

    assert_redirected_to photo_path(photo)
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
    PhotoLocationPlace.create!(
      location_id: PhotoLocation.id_for_coordinates(44.762222, -85.597983),
      name: "Traverse City, Michigan",
      names: [ "Traverse City, Michigan", "Traverse City", "Michigan", "United States" ]
    )

    get photo_path(photo)

    assert_response :success
    assert_includes response.body, "Archive"
    assert_select "section[data-controller~='info-panel'][data-controller~='history-back']"
    assert_select "section[data-controller~='info-panel'] > a.fixed[aria-label='Return to stream'][title='Return to stream'][data-action='history-back#go']"
    assert_select "main a[aria-label='Return to stream']", false
    assert_select "aside#photo-info-panel a", { text: "Back to stream", count: 0 }
    assert_select "button[aria-label='Show photo information'][data-action='info-panel#toggle']"
    assert_select "button[aria-label='Close photo information'][data-action='info-panel#close']"
    assert_select "aside#photo-info-panel.translate-x-full"
    assert_includes response.body, "Fuji X100"
    assert_includes response.body, "3,024 x 4,032"
    assert_includes response.body, "Photo location map"
    assert_includes response.body, "Traverse City, Michigan"
    assert_includes response.body, "Traverse City · Michigan · United States"
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

  test "owner sees video metadata details" do
    photo = attached_video
    photo.create_metadata!(
      extraction_status: "complete",
      width: 1920,
      height: 1080,
      video_codec: "h264",
      audio_codec: "aac",
      video_container: "QuickTime / MOV",
      video_bitrate: 8_250_000,
      video_duration: 65.432,
      video_frame_rate: 29.97,
      raw: {}
    )

    get photo_path(photo)

    assert_response :success
    assert_includes response.body, "QuickTime / MOV"
    assert_includes response.body, "h264 / aac"
    assert_includes response.body, "1:05"
    assert_includes response.body, "8.3 Mbps"
    assert_includes response.body, "29.97 fps"
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
    assert_redirected_to photo_path(photo)
    follow_redirect!

    assert_response :success
    assert_select "main[data-controller='stream-navigation']"
    assert_select "a[href='#{photo_path(newer)}'][data-turbo-action='replace'][aria-label='Previous item in stream'][title='Previous item in stream']"
    assert_select "a[href='#{photo_path(older)}'][data-turbo-action='replace'][aria-label='Next item in stream'][title='Next item in stream']"
    assert_includes response.body, "wheel->stream-navigation#wheel"
    assert_includes response.body, %(data-stream-navigation-back-url-value="#{map_path}")
    assert_includes response.body, %(data-stream-navigation-previous-url-value="#{photo_path(newer)}")
    assert_includes response.body, %(data-stream-navigation-next-url-value="#{photo_path(older)}")
  end

  test "archive detail view uses archived stream neighbors" do
    newer = attached_photo(title: "Archived newer")
    photo = attached_photo(title: "Archived current")
    older = attached_photo(title: "Archived older")
    active = attached_photo(title: "Active")
    newer.update_columns(archived_at: Time.current, created_at: Time.zone.local(2026, 1, 4), updated_at: Time.zone.local(2026, 1, 4))
    active.update_columns(created_at: Time.zone.local(2026, 1, 3), updated_at: Time.zone.local(2026, 1, 3))
    photo.update_columns(archived_at: Time.current, created_at: Time.zone.local(2026, 1, 2), updated_at: Time.zone.local(2026, 1, 2))
    older.update_columns(archived_at: Time.current, created_at: Time.zone.local(2026, 1, 1), updated_at: Time.zone.local(2026, 1, 1))

    get photo_path(photo, return_to: archived_photos_path)
    assert_redirected_to photo_path(photo)
    follow_redirect!

    assert_response :success
    assert_select "a[href='#{photo_path(newer)}'][aria-label='Previous item in stream']"
    assert_select "a[href='#{photo_path(older)}'][aria-label='Next item in stream']"
    refute_includes response.body, photo_path(active)
  end

  test "photo stream renders an infinite scroll sentinel when more photos exist" do
    (Photo::STREAM_PAGE_SIZE + 1).times do |index|
      photo = attached_photo(title: "Stream #{index}")
      photo.update_columns(created_at: index.minutes.ago, updated_at: index.minutes.ago)
    end

    get root_path

    assert_response :success
    assert_select "[data-controller~='infinite-scroll']"
    assert_select "[data-controller~='stream-state']"
    assert_select "[data-infinite-scroll-target='sentinel']"
  end

  test "direct photo detail links back to a focused stream" do
    photo = attached_photo(title: "Direct link")

    get photo_path(photo)

    assert_response :success
    assert_select "a[href='#{root_path(photo_id: photo.id)}'][aria-label='Return to stream']"
    assert_includes response.body, %(data-stream-navigation-back-url-value="#{root_path(photo_id: photo.id)}")
  end

  test "photo stream can render focused around a requested photo" do
    newer = attached_photo(title: "Newer")
    target = attached_photo(title: "Target")
    older = attached_photo(title: "Older")
    newer.update_columns(created_at: Time.zone.local(2026, 1, 3), updated_at: Time.zone.local(2026, 1, 3))
    target.update_columns(created_at: Time.zone.local(2026, 1, 2), updated_at: Time.zone.local(2026, 1, 2))
    older.update_columns(created_at: Time.zone.local(2026, 1, 1), updated_at: Time.zone.local(2026, 1, 1))

    get root_path(photo_id: target.id)

    assert_response :success
    assert_select "[data-stream-state-target-photo-id-value='#{target.id}']"
    assert_select "[data-photo-id='#{target.id}']"
    assert_select "[data-photo-id='#{older.id}']"
    assert_select "[data-photo-id='#{newer.id}']", false
    assert_select "[data-controller~='infinite-scroll']"
    assert_select "[data-stream-page-direction='newer']"
  end

  test "photo stream renders a right side timeline for captured dates" do
    newer = attached_photo(title: "Timeline newer")
    newer.update!(captured_at: Time.zone.local(2024, 5, 12, 10))
    older = attached_photo(title: "Timeline older")
    older.update!(captured_at: Time.zone.local(2018, 2, 4, 10))

    get root_path

    assert_response :success
    assert_select "nav[aria-label='Photo timeline'][data-controller='stream-timeline']"
    assert_select "nav[aria-label='Photo timeline'] [data-stream-timeline-target='label'][role='status']"
    assert_select "button[aria-label*='Jump to May 2024'][data-stream-timeline-period-key-value='2024-05']"
    assert_select "button[aria-label*='Jump to February 2018'][data-stream-timeline-period-key-value='2018-02']"
    assert_select "nav[aria-label='Photo timeline'] button[title]", false
    assert_select "button[data-stream-timeline-page-url-value*='cursor=']"
    assert_select "button[data-stream-timeline-page-url-value*='stream_page=1']"
    assert_select "button[data-stream-timeline-page-url-value*='timeline_page=1']"
  end

  test "timeline stream page renders only photo groups with newer and older sentinels" do
    newer = attached_photo(title: "Timeline page newer")
    newer.update!(captured_at: Time.zone.local(2024, 5, 12, 10))
    current = attached_photo(title: "Timeline page current")
    current.update!(captured_at: Time.zone.local(2021, 6, 10, 10))
    older = attached_photo(title: "Timeline page older")
    older.update!(captured_at: Time.zone.local(2021, 5, 10, 10))

    get root_path(cursor: Photo.stream_cursor_before(Time.zone.local(2021, 7, 1)), stream_page: 1, timeline_page: 1)

    assert_response :success
    assert_select "section#day-2021-06-10"
    assert_select "[data-stream-page-direction='newer'][data-next-url*='newer_cursor=']"
    assert_select "[data-next-url*='cursor=']"
    refute_includes response.body, "William Rockwood"
    assert_includes response.body, current.title
    refute_includes response.body, newer.title
    assert_includes response.body, older.title
  end

  test "photo stream groups photos by day with day-level selection" do
    first = attached_photo(title: "First timeline day")
    first.update!(captured_at: Time.zone.local(2024, 4, 29, 9))
    second = attached_photo(title: "Second timeline day")
    second.update!(captured_at: Time.zone.local(2024, 4, 29, 12))

    get root_path

    assert_response :success
    assert_select ".photo-day-groups"
    assert_select "section#day-2024-04-29[data-bulk-selection-group][data-stream-date-group-key='2024-04-29']"
    assert_select "section#day-2024-04-29.photo-day-group[style*='--day-group-columns']"
    assert_select "section#day-2024-04-29 .photo-day-group-grid"
    assert_select "input[data-bulk-selection-group-toggle][aria-label='Select all photos from Mon, Apr 29, 2024']"
  end

  test "photo stream excludes archived photos" do
    active = attached_photo(title: "Stream photo")
    archived = attached_photo(title: "Archived screenshot")
    archived.archive!

    get root_path

    assert_response :success
    assert_includes response.body, active.title
    refute_includes response.body, archived.title
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

  test "photo viewer can recenter when info panel opens" do
    photo = attached_photo(title: "Centered detail")

    get photo_path(photo)

    assert_response :success
    assert_select "main.photo-viewer-shell[data-info-panel-target='viewer']"
    assert_select "aside#photo-info-panel[data-info-panel-target='panel']"
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

  test "owner video detail renders the display video player" do
    photo = attached_video
    attach_video_derivatives(photo)

    get photo_path(photo)

    assert_response :success
    assert_includes response.body, "<video"
    assert_includes response.body, "controls"
    assert_includes response.body, video_photo_path(photo)
    assert_includes response.body, photo.original_filename
  end

  test "public video detail uses video route and withholds media route" do
    photo = attached_video
    attach_video_derivatives(photo)
    photo.publish!
    delete sign_out_path

    get photo_path(photo)

    assert_response :success
    assert_includes response.body, "<video"
    assert_includes response.body, video_photo_path(photo)
    refute_includes response.body, media_photo_path(photo)
    refute_includes response.body, photo.original_filename
  end

  test "video detail waits for browser compatible display derivative" do
    photo = attached_video

    get photo_path(photo)

    assert_response :success
    assert_includes response.body, "Video derivative processing."
    refute_includes response.body, "<video"
    refute_includes response.body, video_photo_path(photo)
  end

  test "public viewer can access video display derivative for public photos" do
    photo = attached_video
    attach_video_derivatives(photo)
    photo.publish!
    delete sign_out_path

    get video_photo_path(photo)

    assert_response :redirect
    assert_includes response.location, "clip-display.mp4"
  end

  test "video route returns not found until display derivative exists" do
    photo = attached_video

    get video_photo_path(photo)

    assert_response :not_found
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

  def attach_video_derivatives(photo)
    photo.video_preview.attach(
      io: StringIO.new("fake jpg bytes"),
      filename: "clip-preview.jpg",
      content_type: "image/jpeg"
    )
    photo.video_display.attach(
      io: StringIO.new("fake mp4 bytes"),
      filename: "clip-display.mp4",
      content_type: "video/mp4"
    )
  end
end
