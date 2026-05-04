require "test_helper"

class AlbumsControllerTest < ActionDispatch::IntegrationTest
  setup do
    OmniAuth.config.test_mode = true
    @owner = users(:one)
    sign_in_as(@owner)
  end

  teardown do
    OmniAuth.config.mock_auth[:google_oauth2] = nil
    OmniAuth.config.test_mode = false
  end

  test "owner can create and view an album" do
    assert_difference "PhotoAlbum.count", 1 do
      post albums_path, params: { photo_album: { title: "Summer", visibility: "private" } }
    end

    album = PhotoAlbum.last
    assert_redirected_to album_path(album)
    assert_equal @owner, album.owner
    assert_predicate album, :private?

    get album_path(album)
    assert_response :success
    assert_includes response.body, "Summer"
  end

  test "anonymous viewer sees public albums but not private album photos" do
    album = @owner.photo_albums.create!(title: "Shared", source: "manual", visibility: "public")
    public_photo = attached_photo(title: "Public")
    private_photo = attached_photo(title: "Private")
    public_photo.publish!
    album.photos << public_photo
    album.photos << private_photo
    delete sign_out_path

    get albums_path
    assert_response :success
    assert_includes response.body, "Shared"
    assert_includes response.body, "&lt; Stream"
    assert_includes response.body, "1 public, 0 private albums"
    assert_includes response.body, "1 photo"

    get album_path(album)
    assert_response :success
    assert_includes response.body, "Public"
    refute_includes response.body, "Private"
  end

  test "anonymous viewer cannot see private albums" do
    album = @owner.photo_albums.create!(title: "Private album", source: "manual")
    delete sign_out_path

    get album_path(album)

    assert_response :not_found
  end

  test "owner sees public and private album counts" do
    @owner.photo_albums.create!(title: "Private album", source: "manual")
    @owner.photo_albums.create!(title: "Public album", source: "manual", visibility: "public")

    get albums_path

    assert_response :success
    assert_includes response.body, "1 public, 1 private albums"
    assert_includes response.body, "&lt; Stream"
  end

  test "owner can publish and unpublish an album" do
    album = @owner.photo_albums.create!(title: "Trip", source: "manual")

    patch publish_album_path(album)
    assert_redirected_to album_path(album)
    assert_predicate album.reload, :public?

    patch unpublish_album_path(album)
    assert_redirected_to album_path(album)
    assert_predicate album.reload, :private?
  end

  test "owner can rename an album" do
    album = @owner.photo_albums.create!(title: "Old name", source: "manual")

    patch album_path(album), params: { photo_album: { title: "New name", visibility: "public" } }

    assert_redirected_to album_path(album)
    assert_equal "New name", album.reload.title
    assert_predicate album, :public?
  end

  test "owner can remove a photo from an album without deleting it" do
    album = @owner.photo_albums.create!(title: "Trip", source: "manual")
    photo = attached_photo(title: "Album item")
    membership = album.photo_album_memberships.create!(photo: photo)

    assert_no_difference "Photo.count" do
      assert_difference "PhotoAlbumMembership.count", -1 do
        delete photo_album_membership_path(membership)
      end
    end

    assert_redirected_to album_path(album)
  end

  test "owner can set an album cover" do
    album = @owner.photo_albums.create!(title: "Trip", source: "manual")
    photo = attached_photo(title: "Cover")
    album.photos << photo

    patch album_cover_path(album, photo)

    assert_redirected_to album_path(album)
    assert_equal photo, album.reload.cover_photo
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
