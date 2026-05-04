require "test_helper"

class PhotoPeopleTagsControllerTest < ActionDispatch::IntegrationTest
  setup do
    OmniAuth.config.test_mode = true
    @owner = users(:one)
    @viewer = users(:two)
    sign_in_as(@owner)
  end

  teardown do
    OmniAuth.config.mock_auth[:google_oauth2] = nil
    OmniAuth.config.test_mode = false
  end

  test "owner can tag a user and tagged user can see private photo" do
    photo = attached_photo

    post photo_photo_people_tags_path(photo), params: { user_id: @viewer.id }

    assert_redirected_to photo_path(photo)
    assert_includes photo.reload.tagged_users, @viewer

    sign_in_as(@viewer)
    get photo_path(photo)

    assert_response :success
    assert_includes response.body, photo.title
    assert_includes response.body, "People"
    assert_includes response.body, @viewer.display_name
  end

  test "owner can remove a people tag" do
    photo = attached_photo
    tag = photo.photo_people_tags.create!(user: @viewer, tagged_by: @owner)

    delete photo_people_tag_path(tag)

    assert_redirected_to photo_path(photo)
    assert_empty photo.reload.photo_people_tags
  end

  private

  def attached_photo
    photo = @owner.photos.new(title: "Tagged private")
    photo.original.attach(
      io: File.open(Rails.root.join("public/icon.png")),
      filename: "fixture.png",
      content_type: "image/png"
    )
    photo.save!
    photo
  end

  def sign_in_as(user)
    OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new(
      provider: user.provider,
      uid: user.uid,
      info: { email: user.email, name: user.name, image: user.avatar_url }
    )
    post "/auth/google_oauth2"
    follow_redirect!
  end
end
