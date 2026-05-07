require "test_helper"
require "zip"

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

  test "invited viewer sees shared private albums and private album photos" do
    album = @owner.photo_albums.create!(title: "Family album", source: "manual")
    unshared_album = @owner.photo_albums.create!(title: "Unshared album", source: "manual")
    private_photo = attached_photo(title: "Family private")
    unshared_photo = attached_photo(title: "Unshared private")
    locked_photo = attached_photo(title: "Locked album item")
    locked_photo.restrict!
    album.photos << private_photo
    album.photos << locked_photo
    unshared_album.photos << unshared_photo
    album.photo_album_shares.create!(user: users(:two), shared_by: @owner)
    delete sign_out_path
    sign_in_as(users(:two))

    get albums_path

    assert_response :success
    assert_includes response.body, "Family album"
    refute_includes response.body, "Unshared album"

    get album_path(album)

    assert_response :success
    assert_includes response.body, "Family private"
    refute_includes response.body, "Locked album item"

    get album_path(unshared_album)

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
    assert_select "summary", text: "Album info"
    assert_select "button", text: "Delete album"
    assert_select "form[action='#{album_path(album)}'][method='post'] input[name='_method'][value='delete']"
    assert_includes response.body, "The photos stay in your library."
  end

  test "owner can share and unshare a private album with an invited user" do
    album = @owner.photo_albums.create!(title: "Private Trip", source: "manual")
    viewer = users(:two)

    get album_path(album)

    assert_response :success
    assert_select "form[action='#{album_album_shares_path(album)}'][method='post'] option[value='#{viewer.id}']", text: viewer.display_name

    assert_difference "PhotoAlbumShare.count", 1 do
      post album_album_shares_path(album), params: { user_id: viewer.id }
    end

    assert_redirected_to album_path(album)
    share = album.photo_album_shares.find_by!(user: viewer)

    get album_path(album)

    assert_response :success
    assert_includes response.body, viewer.email
    assert_select "form[action='#{album_share_path(share)}'][method='post'] input[name='_method'][value='delete']"

    assert_difference "PhotoAlbumShare.count", -1 do
      delete album_share_path(share)
    end

    assert_redirected_to album_path(album)
  end

  test "owner sees album download action while viewing an album" do
    album = @owner.photo_albums.create!(title: "Trip", source: "manual")

    get album_path(album)

    assert_response :success
    assert_select "button[data-action='album-download#start']", text: "Download ZIP"
    assert_includes response.body, album_downloads_path(album_id: album.id)
  end

  test "owner can prepare and download visible album originals as a zip" do
    album = @owner.photo_albums.create!(title: "Trip Stuff!", source: "manual")
    visible = attached_photo(title: "Visible Photo")
    archived = attached_photo(title: "Archived Photo")
    archived.archive!
    album.photos << visible
    album.photos << archived

    perform_enqueued_jobs do
      post album_downloads_path(album_id: album.id), as: :json
    end

    assert_response :accepted
    payload = JSON.parse(response.body)
    download = AlbumDownload.find(payload.fetch("id"))
    assert_predicate download, :ready?
    assert_equal 1, download.total_entries
    assert_equal 1, download.processed_entries

    get album_download_path(download), as: :json
    assert_response :success
    payload = JSON.parse(response.body)
    assert_equal "ready", payload.fetch("status")
    assert_equal file_album_download_path(download), payload.fetch("file_url")

    get file_album_download_path(download)
    assert_redirected_to rails_blob_path(download.archive, disposition: "attachment")

    download.archive.open do |file|
      Zip::File.open(file.path) do |zip|
        assert_equal [ "0001-visible-photo.png" ], zip.map(&:name)
        assert_equal File.binread(Rails.root.join("public/icon.png")), zip.read("0001-visible-photo.png")
      end
    end
  end

  test "non owner cannot prepare an album zip" do
    album = @owner.photo_albums.create!(title: "Trip", source: "manual")
    delete sign_out_path

    post album_downloads_path(album_id: album.id), as: :json

    assert_response :forbidden
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
    assert_select ".photo-flat-pages"
    assert_select ".photo-flat-grid"
    assert_select "[data-stream-date-group-key]", false
  end

  test "album page can focus around a returned photo" do
    album = @owner.photo_albums.create!(title: "Concert", source: "manual")
    newer = attached_photo(title: "Newer album photo")
    target = attached_photo(title: "Returned album photo")
    older = attached_photo(title: "Older album photo")
    [ newer, target, older ].each { |photo| album.photos << photo }
    newer.update_columns(created_at: Time.zone.local(2026, 1, 3), updated_at: Time.zone.local(2026, 1, 3))
    target.update_columns(created_at: Time.zone.local(2026, 1, 2), updated_at: Time.zone.local(2026, 1, 2))
    older.update_columns(created_at: Time.zone.local(2026, 1, 1), updated_at: Time.zone.local(2026, 1, 1))

    get album_path(album, photo_id: target.id)

    assert_response :success
    assert_select "[data-stream-state-target-photo-id-value='#{target.id}']"
    assert_select "[data-photo-id='#{target.id}']"
    assert_select "[data-photo-id='#{older.id}']"
  end

  test "album infinite scroll pages do not render date groups" do
    album = @owner.photo_albums.create!(title: "Concert", source: "manual")
    album.photos << attached_photo(title: "First")
    album.photos << attached_photo(title: "Second")

    get album_path(album, stream_page: 1)

    assert_response :success
    assert_select ".photo-flat-pages", false
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

  test "owner can remove a photo from an album and return near album position" do
    album = @owner.photo_albums.create!(title: "Trip", source: "manual")
    newer = attached_photo(title: "Newer album item")
    target = attached_video(title: "Removed album item")
    older = attached_photo(title: "Older album item")
    [ newer, target, older ].each { |photo| album.photos << photo }
    set_stream_time(newer, Time.zone.local(2026, 1, 3))
    set_stream_time(target, Time.zone.local(2026, 1, 2))
    set_stream_time(older, Time.zone.local(2026, 1, 1))

    assert_no_difference "Photo.count" do
      assert_difference "PhotoAlbumMembership.count", -1 do
        delete photo_album_membership_path(album.photo_album_memberships.find_by!(photo: target)),
          params: { return_to: album_path(album, photo_id: target.id) }
      end
    end

    assert_redirected_to album_path(album, photo_id: older.id)
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

  def set_stream_time(photo, time)
    photo.update_columns(captured_at: time, created_at: time, updated_at: time)
  end
end
