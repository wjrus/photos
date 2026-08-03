require "test_helper"

class AlbumAccessLinkTest < ActiveSupport::TestCase
  setup do
    @owner = users(:one)
    @album = @owner.photo_albums.create!(title: "Shared trip", source: "manual")
  end

  test "signed key authenticates only for its album" do
    link = @album.album_access_links.create!(created_by: @owner, label: "Friends")
    other_album = @owner.photo_albums.create!(title: "Other trip", source: "manual")

    assert_equal link, AlbumAccessLink.authenticate(album: @album, key: link.key)
    assert_nil AlbumAccessLink.authenticate(album: other_album, key: link.key)
    assert_nil AlbumAccessLink.authenticate(album: @album, key: "not-a-valid-key")
  end

  test "key is short URL-safe and unique" do
    first = @album.album_access_links.create!(created_by: @owner, label: "Friends")
    second = @album.album_access_links.create!(created_by: @owner, label: "Family")

    assert_match(/\A[A-Za-z0-9_-]{16}\z/, first.key)
    assert_match(/\A[A-Za-z0-9_-]{16}\z/, second.key)
    assert_not_equal first.key, second.key
  end

  test "legacy signed keys remain valid" do
    link = @album.album_access_links.create!(created_by: @owner, label: "Existing link")
    legacy_key = link.signed_id(purpose: :album_access)

    assert_equal link, AlbumAccessLink.authenticate(album: @album, key: legacy_key)
  end

  test "revoked and expired links do not authenticate" do
    revoked = @album.album_access_links.create!(created_by: @owner, label: "Revoked")
    expiring = @album.album_access_links.create!(
      created_by: @owner,
      label: "Weekend",
      expires_at: 1.hour.from_now
    )
    expiring_key = expiring.key

    revoked.revoke!

    assert_nil AlbumAccessLink.authenticate(album: @album, key: revoked.key)
    travel 2.hours do
      assert_nil AlbumAccessLink.authenticate(album: @album, key: expiring_key)
    end
  end

  test "records access count and last access time" do
    link = @album.album_access_links.create!(created_by: @owner, label: "Family")

    assert_changes -> { link.reload.access_count }, from: 0, to: 1 do
      link.record_access!
    end
    assert_in_delta Time.current, link.last_accessed_at, 1.second
  end

  test "expiration must be in the future" do
    link = @album.album_access_links.new(
      created_by: @owner,
      label: "Already over",
      expires_at: 1.minute.ago
    )

    assert_not link.valid?
    assert_includes link.errors[:expires_at], "must be in the future"
  end
end
