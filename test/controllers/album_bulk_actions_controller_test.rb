require "test_helper"

class AlbumBulkActionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    OmniAuth.config.test_mode = true
    @owner = users(:one)
    sign_in_as(@owner)
  end

  teardown do
    OmniAuth.config.mock_auth[:google_oauth2] = nil
    OmniAuth.config.test_mode = false
  end

  test "owner can bulk publish and unpublish albums" do
    first = @owner.photo_albums.create!(title: "First", source: "manual")
    second = @owner.photo_albums.create!(title: "Second", source: "manual")

    post album_bulk_actions_path, params: { bulk_action: "publish", album_ids: [ first.id, second.id ] }

    assert_redirected_to albums_path
    assert_predicate first.reload, :public?
    assert_predicate second.reload, :public?

    post album_bulk_actions_path, params: { bulk_action: "unpublish", album_ids: [ first.id, second.id ] }

    assert_redirected_to albums_path
    assert_predicate first.reload, :private?
    assert_predicate second.reload, :private?
  end

  test "owner can bulk delete albums without deleting photos" do
    photo = attached_photo(title: "Kept")
    album = @owner.photo_albums.create!(title: "Delete album", source: "manual")
    album.photos << photo

    assert_difference "PhotoAlbum.count", -1 do
      assert_no_difference "Photo.count" do
        post album_bulk_actions_path, params: { bulk_action: "delete", album_ids: [ album.id ] }
      end
    end

    assert_redirected_to albums_path
  end

  test "non owner cannot bulk manage albums" do
    album = @owner.photo_albums.create!(title: "Owner only", source: "manual")
    delete sign_out_path
    sign_in_as(users(:two))

    post album_bulk_actions_path, params: { bulk_action: "publish", album_ids: [ album.id ] }

    assert_redirected_to root_path
    assert_predicate album.reload, :private?
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
