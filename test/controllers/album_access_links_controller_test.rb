require "test_helper"

class AlbumAccessLinksControllerTest < ActionDispatch::IntegrationTest
  setup do
    OmniAuth.config.test_mode = true
    @owner = users(:one)
    @album = @owner.photo_albums.create!(title: "Family", source: "manual")
    sign_in_as(@owner)
  end

  teardown do
    OmniAuth.config.mock_auth[:google_oauth2] = nil
    OmniAuth.config.test_mode = false
  end

  test "owner creates a labeled expiring link" do
    freeze_time do
      assert_difference "AlbumAccessLink.count", 1 do
        post album_access_links_path(@album), params: { label: "Reunion", expires_in: "30_days" }
      end

      link = AlbumAccessLink.last
      assert_redirected_to album_path(@album)
      assert_equal "Reunion", link.label
      assert_equal @owner, link.created_by
      assert_equal 30.days.from_now, link.expires_at
    end
  end

  test "owner revokes a link without losing its usage history" do
    link = @album.album_access_links.create!(
      created_by: @owner,
      label: "Friends",
      access_count: 3,
      last_accessed_at: 1.hour.ago
    )

    patch revoke_album_access_link_path(link)

    assert_redirected_to album_path(@album)
    assert_predicate link.reload, :revoked?
    assert_equal 3, link.access_count
    assert_not_nil link.last_accessed_at
  end

  test "invalid expiration does not create a link" do
    assert_no_difference "AlbumAccessLink.count" do
      post album_access_links_path(@album), params: { expires_in: "tomorrow-ish" }
    end

    assert_redirected_to album_path(@album)
  end

  test "viewer cannot create or revoke links" do
    link = @album.album_access_links.create!(created_by: @owner, label: "Existing")
    delete sign_out_path
    sign_in_as(users(:two))

    assert_no_difference "AlbumAccessLink.count" do
      post album_access_links_path(@album), params: { expires_in: "never" }
    end
    assert_redirected_to root_path

    patch revoke_album_access_link_path(link)
    assert_redirected_to root_path
    assert_predicate link.reload, :active?
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
end
