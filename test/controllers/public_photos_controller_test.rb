require "test_helper"

class PublicPhotosControllerTest < ActionDispatch::IntegrationTest
  setup do
    OmniAuth.config.test_mode = true
    @owner = users(:one)
    sign_in_as(@owner)
  end

  teardown do
    OmniAuth.config.mock_auth[:google_oauth2] = nil
    OmniAuth.config.test_mode = false
  end

  test "owner sees only public active photos" do
    public_photo = attached_photo(title: "Published lake")
    public_photo.publish!
    private_photo = attached_photo(title: "Private lake")
    archived_public = attached_photo(title: "Archived published lake")
    archived_public.publish!
    archived_public.archive!
    locked_public = attached_photo(title: "Locked published lake")
    locked_public.publish!
    locked_public.restrict!

    get public_photos_path

    assert_response :success
    assert_includes response.body, "Public photos"
    assert_includes response.body, public_photo.title
    refute_includes response.body, private_photo.title
    refute_includes response.body, archived_public.title
    refute_includes response.body, locked_public.title
    assert_select "form#public-photo-bulk-form"
    assert_select "input[name='return_to'][value='#{public_photos_path}']"
  end

  test "non owner cannot open public owner stream" do
    delete sign_out_path
    sign_in_as(users(:two))

    get public_photos_path

    assert_redirected_to root_path
  end

  test "public stream renders timeline and focused pages" do
    newer = attached_photo(title: "Public timeline newer")
    target = attached_photo(title: "Public timeline target")
    older = attached_photo(title: "Public timeline older")
    [ newer, target, older ].each(&:publish!)
    set_stream_time(newer, Time.zone.local(2024, 5, 12, 10))
    set_stream_time(target, Time.zone.local(2021, 6, 10, 10))
    set_stream_time(older, Time.zone.local(2020, 2, 4, 10))

    get public_photos_path(photo_id: target.id)

    assert_response :success
    assert_select "[data-stream-state-target-photo-id-value='#{target.id}']"
    assert_select "nav[aria-label='Photo timeline'][data-controller='stream-timeline']"
    assert_select "button[aria-label*='Jump to May 2024'][data-stream-timeline-page-url-value^='#{public_photos_path}']"
    assert_select "button[aria-label*='Jump to February 2020'][data-stream-timeline-page-url-value^='#{public_photos_path}']"
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
    photo.update_columns(captured_at: time, created_at: time, updated_at: time)
  end
end
