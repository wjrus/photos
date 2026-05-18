require "test_helper"

class UserTest < ActiveSupport::TestCase
  test "creates user from google auth data" do
    auth = OmniAuth::AuthHash.new(
      provider: "google_oauth2",
      uid: "google-789",
      credentials: {
        token: "access-token",
        refresh_token: "refresh-token",
        expires_at: 1.hour.from_now.to_i,
        scope: "openid email profile"
      },
      info: {
        email: "Traveler@Example.com",
        name: "Summer Traveler",
        image: "https://example.com/avatar.jpg"
      }
    )

    user = User.from_omniauth(auth)

    assert_equal "google_oauth2", user.provider
    assert_equal "google-789", user.uid
    assert_equal "traveler@example.com", user.email
    assert_equal "Summer Traveler", user.name
    assert_equal "viewer", user.role
    assert_nil user.google_access_token
    assert_nil user.google_refresh_token
    assert_not_predicate user, :google_drive_authorized?
    assert_predicate user.last_signed_in_at, :present?
  end

  test "stores google drive tokens only for owner when drive scope is granted" do
    previous_owner_email = ENV["PHOTOS_OWNER_EMAIL"]
    ENV["PHOTOS_OWNER_EMAIL"] = "owner@example.com"
    auth = OmniAuth::AuthHash.new(
      provider: "google_oauth2",
      uid: "google-owner-drive",
      credentials: {
        token: "owner-access-token",
        refresh_token: "owner-refresh-token",
        expires_at: 1.hour.from_now.to_i,
        scope: "openid email profile #{GoogleDriveArchiveClient::DRIVE_SCOPE}"
      },
      info: {
        email: "Owner@Example.com",
        name: "Owner",
        image: nil
      }
    )

    user = User.from_omniauth(auth)

    assert_predicate user, :owner?
    assert_equal "owner-access-token", user.google_access_token
    assert_equal "owner-refresh-token", user.google_refresh_token
    assert_predicate user, :google_drive_authorized?
  ensure
    ENV["PHOTOS_OWNER_EMAIL"] = previous_owner_email
  end

  test "does not store drive tokens for viewers even if drive scope is granted" do
    auth = OmniAuth::AuthHash.new(
      provider: "google_oauth2",
      uid: "google-viewer-drive",
      credentials: {
        token: "viewer-access-token",
        refresh_token: "viewer-refresh-token",
        expires_at: 1.hour.from_now.to_i,
        scope: "openid email profile #{GoogleDriveArchiveClient::DRIVE_SCOPE}"
      },
      info: {
        email: "viewer-drive@example.com",
        name: "Viewer",
        image: nil
      }
    )

    user = User.from_omniauth(auth)

    assert_predicate user, :viewer?
    assert_nil user.google_access_token
    assert_nil user.google_refresh_token
    assert_not_predicate user, :google_drive_authorized?
  end

  test "marks configured owner email as owner" do
    previous_owner_email = ENV["PHOTOS_OWNER_EMAIL"]
    ENV["PHOTOS_OWNER_EMAIL"] = "owner@example.com"
    auth = OmniAuth::AuthHash.new(
      provider: "google_oauth2",
      uid: "google-owner",
      info: {
        email: "Owner@Example.com",
        name: "Owner",
        image: nil
      }
    )

    assert_predicate User.from_omniauth(auth), :owner?
  ensure
    ENV["PHOTOS_OWNER_EMAIL"] = previous_owner_email
  end

  test "updates existing google user on later sign in" do
    user = users(:two)
    auth = OmniAuth::AuthHash.new(
      provider: user.provider,
      uid: user.uid,
      info: {
        email: "friend@example.com",
        name: "Updated Friend",
        image: "https://example.com/new.jpg"
      }
    )

    assert_no_difference "User.count" do
      User.from_omniauth(auth)
    end

    assert_equal "Updated Friend", user.reload.name
    assert_equal "https://example.com/new.jpg", user.avatar_url
  end
end
