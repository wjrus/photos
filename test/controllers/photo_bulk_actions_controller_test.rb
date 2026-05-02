require "test_helper"

class PhotoBulkActionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    OmniAuth.config.test_mode = true
    @owner = users(:one)
    sign_in_as(@owner)
  end

  teardown do
    OmniAuth.config.mock_auth[:google_oauth2] = nil
    OmniAuth.config.test_mode = false
  end

  test "owner can bulk publish and unpublish photos" do
    first = attached_photo(title: "First")
    second = attached_photo(title: "Second")

    post photo_bulk_actions_path, params: { bulk_action: "publish", photo_ids: [ first.id, second.id ] }

    assert_redirected_to root_path
    assert_predicate first.reload, :public?
    assert_predicate second.reload, :public?

    post photo_bulk_actions_path, params: { bulk_action: "unpublish", photo_ids: [ first.id, second.id ] }

    assert_redirected_to root_path
    assert_predicate first.reload, :private?
    assert_predicate second.reload, :private?
  end

  test "owner can add selected photos to an existing album" do
    album = @owner.photo_albums.create!(title: "Existing", source: "manual")
    photo = attached_photo(title: "For album")

    assert_difference "PhotoAlbumMembership.count", 1 do
      post photo_bulk_actions_path, params: { bulk_action: "add_to_album", album_id: album.id, photo_ids: [ photo.id ] }
    end

    assert_redirected_to root_path
    assert_includes album.reload.photos, photo
  end

  test "owner can add selected photos to a new album" do
    photo = attached_photo(title: "New album photo")

    assert_difference "PhotoAlbum.count", 1 do
      assert_difference "PhotoAlbumMembership.count", 1 do
        post photo_bulk_actions_path, params: { bulk_action: "add_to_album", new_album_title: "New York", photo_ids: [ photo.id ] }
      end
    end

    album = PhotoAlbum.find_by!(title: "New York")
    assert_redirected_to root_path
    assert_includes album.photos, photo
  end

  test "owner can bulk delete photos" do
    first = attached_photo(title: "Delete first")
    second = attached_photo(title: "Delete second")

    assert_difference "Photo.count", -2 do
      post photo_bulk_actions_path, params: { bulk_action: "delete", photo_ids: [ first.id, second.id ] }
    end

    assert_redirected_to root_path
  end

  test "non owner cannot bulk manage photos" do
    photo = attached_photo(title: "Owner only")
    delete sign_out_path
    sign_in_as(users(:two))

    post photo_bulk_actions_path, params: { bulk_action: "publish", photo_ids: [ photo.id ] }

    assert_redirected_to root_path
    assert_predicate photo.reload, :private?
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
end
