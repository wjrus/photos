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
    archived.original.variant(:stream).processed
    archived.archive!
    active = attached_photo(title: "Vacation")

    get archived_photos_path

    assert_response :success
    assert_includes response.body, "Archive"
    assert_includes response.body, archived.title
    refute_includes response.body, active.title
    assert_includes response.body, stream_photo_path(archived)
    assert_includes response.body, "return_to=%2Farchive"
    assert_select "form#archive-photo-bulk-form"
    assert_select "button[value='restore'][aria-label='Restore selected photos to stream']"

    get stream_photo_path(archived, return_to: archived_photos_path)

    assert_response :success
  end

  test "non owner cannot open archive" do
    delete sign_out_path
    sign_in_as(users(:two))

    get archived_photos_path

    assert_redirected_to root_path
  end

  test "archive stream renders timeline scoped to archived photos" do
    newer = attached_photo(title: "Archive timeline newer")
    older = attached_photo(title: "Archive timeline older")
    active = attached_photo(title: "Active timeline outside")
    [ newer, older ].each(&:archive!)
    set_stream_time(newer, Time.zone.local(2024, 5, 12, 10))
    set_stream_time(older, Time.zone.local(2020, 2, 4, 10))
    set_stream_time(active, Time.zone.local(2018, 2, 4, 10))

    get archived_photos_path

    assert_response :success
    assert_select "nav[aria-label='Photo timeline'][data-controller='stream-timeline']"
    assert_select "button[aria-label*='Jump to May 2024'][data-stream-timeline-page-url-value^='#{archived_photos_path}']"
    assert_select "button[aria-label*='Jump to February 2020'][data-stream-timeline-page-url-value^='#{archived_photos_path}']"
    refute_includes response.body, "February 2018"

    get archived_photos_path(cursor: Photo.stream_cursor_before(Time.zone.local(2021, 1, 1)), stream_page: 1, timeline_page: 1)

    assert_response :success
    assert_includes response.body, older.title
    refute_includes response.body, newer.title
    refute_includes response.body, active.title
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

  def set_stream_time(photo, time)
    PhotoMetadata.for_photo(photo).update!(captured_at: time)
    photo.update_columns(captured_at: time, created_at: time, updated_at: time)
  end
end
