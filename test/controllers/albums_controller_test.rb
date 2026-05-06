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

  test "album index splits visible photo and video counts" do
    mixed_album = @owner.photo_albums.create!(title: "Mixed", source: "manual")
    video_album = @owner.photo_albums.create!(title: "Videos", source: "manual")
    photo_album = @owner.photo_albums.create!(title: "Photos", source: "manual")

    mixed_album.photos << attached_photo(title: "Mixed photo")
    mixed_album.photos << attached_video(title: "Mixed video")
    video_album.photos << attached_video(title: "Only video")
    photo_album.photos << attached_photo(title: "Only photo")

    get albums_path

    assert_response :success
    assert_select "article", text: /Mixed.*1 photo, 1 video/m
    assert_select "article", text: /Videos.*1 video/m
    assert_select "article", text: /Photos.*1 photo/m
  end

  test "album detail splits visible photo and video counts" do
    album = @owner.photo_albums.create!(title: "Mixed detail", source: "manual")
    album.photos << attached_photo(title: "Still")
    album.photos << attached_video(title: "Motion")

    get album_path(album)

    assert_response :success
    assert_select "p", text: /1 photo, 1 video/
  end

  test "album index is sorted alphabetically" do
    @owner.photo_albums.create!(title: "zebra trip", source: "manual")
    @owner.photo_albums.create!(title: "Apple trip", source: "manual")
    @owner.photo_albums.create!(title: "middle trip", source: "manual")

    get albums_path

    assert_response :success
    assert_operator response.body.index("Apple trip"), :<, response.body.index("middle trip")
    assert_operator response.body.index("middle trip"), :<, response.body.index("zebra trip")
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

  test "owner sees delete album action while viewing an album" do
    album = @owner.photo_albums.create!(title: "Trip", source: "manual")

    get album_path(album)

    assert_response :success
    assert_select "button", text: "Delete album"
    assert_select "form[action='#{album_path(album)}'][method='post'] input[name='_method'][value='delete']"
    assert_includes response.body, "The photos stay in your library."
  end

  test "owner can delete an album without deleting photos" do
    album = @owner.photo_albums.create!(title: "Trip", source: "manual")
    photo = attached_photo(title: "Album item")
    album.photos << photo

    assert_no_difference "Photo.count" do
      assert_difference "PhotoAlbum.count", -1 do
        assert_difference "PhotoAlbumMembership.count", -1 do
          delete album_path(album)
        end
      end
    end

    assert_redirected_to albums_path
    assert Photo.exists?(photo.id)
  end

  test "album photo grid does not repeat date groups" do
    album = @owner.photo_albums.create!(title: "Concert", source: "manual")
    album.photos << attached_photo(title: "First")
    album.photos << attached_photo(title: "Second")

    get album_path(album)

    assert_response :success
    assert_select ".photo-flat-grid"
    assert_select "[data-stream-date-group-key]", false
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

  def attached_video(title:)
    photo = @owner.photos.new(title: title)
    photo.original.attach(
      io: StringIO.new("fake mp4 bytes"),
      filename: "#{title.parameterize}.mp4",
      content_type: "video/mp4"
    )
    photo.save!
    photo
  end
end
