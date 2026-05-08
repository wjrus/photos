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

  test "bulk add to album from stream returns to selected photo" do
    album = @owner.photo_albums.create!(title: "Existing", source: "manual")
    photo = attached_photo(title: "For album")

    post photo_bulk_actions_path, params: {
      bulk_action: "add_to_album",
      album_id: album.id,
      photo_ids: [ photo.id ],
      return_to: root_path
    }

    assert_redirected_to root_path(photo_id: photo.id)
    assert_includes album.reload.photos, photo
  end

  test "bulk add to album from another album returns to selected photo in current album" do
    current_album = @owner.photo_albums.create!(title: "Current", source: "manual")
    target_album = @owner.photo_albums.create!(title: "Target", source: "manual")
    photo = attached_photo(title: "Cross album add")
    current_album.photos << photo

    post photo_bulk_actions_path, params: {
      bulk_action: "add_to_album",
      album_id: target_album.id,
      photo_ids: [ photo.id ],
      return_to: album_path(current_album)
    }

    assert_redirected_to album_path(current_album, photo_id: photo.id)
    assert_includes target_album.reload.photos, photo
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

  test "owner can bulk set image photo location" do
    first = attached_photo(title: "Location first")
    second = attached_photo(title: "Location second")
    first.create_metadata!(extraction_status: "complete", raw: { "camera" => "kept" })
    geocoder = stub_address_geocoder(
      latitude: BigDecimal("44.760800"),
      longitude: BigDecimal("-85.622800"),
      name: "Traverse City, MI, USA",
      names: [ "Traverse City, MI, USA", "Traverse City", "Michigan", "United States" ],
      raw: { "place_id" => "tc123" }
    )

    LocationAddressGeocoder.stub(:new, geocoder) do
      post photo_bulk_actions_path, params: {
        bulk_action: "set_location",
        location_address: "Traverse City, MI",
        photo_ids: [ first.id, second.id ],
        return_to: root_path
      }
    end

    assert_redirected_to root_path(photo_id: first.id)
    assert_equal "Set location for 2 photos.", flash[:notice]
    [ first, second ].each do |photo|
      metadata = photo.reload.metadata
      assert_equal BigDecimal("44.760800"), metadata.latitude
      assert_equal BigDecimal("-85.622800"), metadata.longitude
      assert_equal "Traverse City, MI", metadata.raw.dig("manual_location", "address")
    end
    assert_equal "kept", first.metadata.raw.dig("camera")
    place = PhotoLocationPlace.find_by!(location_id: PhotoLocation.id_for_coordinates(44.760800, -85.622800))
    assert_equal "Traverse City, MI, USA", place.name
  end

  test "bulk set location skips selected videos" do
    image = attached_photo(title: "Location image")
    video = attached_video(title: "Location video")
    geocoder = stub_address_geocoder(
      latitude: BigDecimal("44.760800"),
      longitude: BigDecimal("-85.622800"),
      name: "Traverse City, MI, USA",
      names: [ "Traverse City, MI, USA" ],
      raw: {}
    )

    LocationAddressGeocoder.stub(:new, geocoder) do
      post photo_bulk_actions_path, params: {
        bulk_action: "set_location",
        location_address: "Traverse City, MI",
        photo_ids: [ image.id, video.id ]
      }
    end

    assert_redirected_to root_path
    assert_equal "Set location for 1 photo. Skipped 1 non-image item.", flash[:notice]
    assert_predicate image.reload.metadata, :location?
    assert_nil video.reload.metadata
  end

  test "bulk set location requires an address and an image selection" do
    image = attached_photo(title: "Needs address")

    post photo_bulk_actions_path, params: {
      bulk_action: "set_location",
      location_address: "",
      photo_ids: [ image.id ]
    }

    assert_redirected_to root_path
    assert_equal "Enter an address or place name.", flash[:alert]
    assert_nil image.reload.metadata

    video = attached_video(title: "Only video")
    post photo_bulk_actions_path, params: {
      bulk_action: "set_location",
      location_address: "Traverse City, MI",
      photo_ids: [ video.id ]
    }

    assert_redirected_to root_path
    assert_equal "Select at least one image photo.", flash[:alert]
    assert_nil video.reload.metadata
  end

  test "bulk add to new album from stream returns to selected photo" do
    photo = attached_photo(title: "New album photo")

    post photo_bulk_actions_path, params: {
      bulk_action: "add_to_album",
      new_album_title: "New York",
      photo_ids: [ photo.id ],
      return_to: root_path
    }

    album = PhotoAlbum.find_by!(title: "New York")
    assert_redirected_to root_path(photo_id: photo.id)
    assert_includes album.photos, photo
  end

  test "owner can remove selected photos from the current album" do
    album = @owner.photo_albums.create!(title: "Trip", source: "manual")
    first = attached_photo(title: "Album first")
    second = attached_photo(title: "Album second")
    album.photos << first
    album.photos << second
    album.update!(cover_photo: first)

    assert_difference "PhotoAlbumMembership.count", -2 do
      post photo_bulk_actions_path, params: {
        bulk_action: "remove_from_album",
        context_album_id: album.id,
        photo_ids: [ first.id, second.id ],
        return_to: album_path(album)
      }
    end

    assert_redirected_to album_path(album)
    assert_empty album.reload.photos
    assert_nil album.cover_photo
  end

  test "bulk remove from album returns near album stream position" do
    album = @owner.photo_albums.create!(title: "Trip", source: "manual")
    first = attached_photo(title: "Album remove first")
    second = attached_photo(title: "Album remove second")
    anchor = attached_photo(title: "Album remove anchor")
    album.photos << [ first, second, anchor ]
    set_stream_time(first, 3.days.ago)
    set_stream_time(second, 2.days.ago)
    set_stream_time(anchor, 1.day.ago)

    post photo_bulk_actions_path, params: {
      bulk_action: "remove_from_album",
      context_album_id: album.id,
      photo_ids: [ first.id, second.id ],
      return_to: album_path(album)
    }

    assert_redirected_to album_path(album, photo_id: anchor.id)
    assert_includes album.reload.photos, anchor
    refute_includes album.photos, first
    refute_includes album.photos, second
  end

  test "owner can set selected photo as the current album cover" do
    album = @owner.photo_albums.create!(title: "Trip", source: "manual")
    photo = attached_photo(title: "New cover")
    album.photos << photo

    post photo_bulk_actions_path, params: {
      bulk_action: "set_album_cover",
      context_album_id: album.id,
      photo_ids: [ photo.id ],
      return_to: album_path(album)
    }

    assert_redirected_to album_path(album, photo_id: photo.id)
    assert_equal photo, album.reload.cover_photo
  end

  test "bulk set album cover returns to selected photo in album stream" do
    album = @owner.photo_albums.create!(title: "Trip", source: "manual")
    photo = attached_photo(title: "Focused cover")
    album.photos << photo

    post photo_bulk_actions_path, params: {
      bulk_action: "set_album_cover",
      context_album_id: album.id,
      photo_ids: [ photo.id ],
      return_to: album_path(album)
    }

    assert_redirected_to album_path(album, photo_id: photo.id)
    assert_equal photo, album.reload.cover_photo
  end

  test "setting album cover requires one selected photo" do
    album = @owner.photo_albums.create!(title: "Trip", source: "manual")
    first = attached_photo(title: "First cover choice")
    second = attached_photo(title: "Second cover choice")
    album.photos << first
    album.photos << second

    post photo_bulk_actions_path, params: {
      bulk_action: "set_album_cover",
      context_album_id: album.id,
      photo_ids: [ first.id, second.id ],
      return_to: album_path(album)
    }

    assert_redirected_to album_path(album)
    assert_nil album.reload.cover_photo
  end

  test "owner can bulk delete photos" do
    first = attached_photo(title: "Delete first")
    second = attached_photo(title: "Delete second")

    assert_difference "Photo.count", -2 do
      post photo_bulk_actions_path, params: { bulk_action: "delete", photo_ids: [ first.id, second.id ] }
    end

    assert_redirected_to root_path
  end

  test "owner can bulk archive and restore photos" do
    first = attached_photo(title: "Archive first")
    second = attached_photo(title: "Archive second")

    post photo_bulk_actions_path, params: { bulk_action: "archive", photo_ids: [ first.id, second.id ] }

    assert_redirected_to root_path
    assert_predicate first.reload, :archived?
    assert_predicate second.reload, :archived?

    post photo_bulk_actions_path, params: { bulk_action: "restore", photo_ids: [ first.id, second.id ], return_to: archived_photos_path }

    assert_redirected_to archived_photos_path
    assert_not first.reload.archived?
    assert_not second.reload.archived?
  end

  test "bulk archive reports selected count and returns near archived stream position" do
    newer = attached_photo(title: "Newer stream item")
    first = attached_photo(title: "Older archive first")
    second = attached_photo(title: "Older archive second")
    anchor = attached_photo(title: "Nearby remaining item")
    newer.update_columns(captured_at: Time.zone.local(2024, 1, 1), created_at: Time.zone.local(2024, 1, 1), updated_at: Time.zone.local(2024, 1, 1))
    first.update_columns(captured_at: Time.zone.local(2014, 1, 3), created_at: Time.zone.local(2014, 1, 3), updated_at: Time.zone.local(2014, 1, 3))
    second.update_columns(captured_at: Time.zone.local(2014, 1, 2), created_at: Time.zone.local(2014, 1, 2), updated_at: Time.zone.local(2014, 1, 2))
    anchor.update_columns(captured_at: Time.zone.local(2014, 1, 1), created_at: Time.zone.local(2014, 1, 1), updated_at: Time.zone.local(2014, 1, 1))

    post photo_bulk_actions_path, params: {
      bulk_action: "archive",
      photo_ids: [ first.id, second.id ],
      return_to: root_path
    }

    assert_redirected_to root_path(photo_id: anchor.id)
    assert_equal "Archived 2 photos.", flash[:notice]
    assert_predicate first.reload, :archived?
    assert_predicate second.reload, :archived?
    refute_predicate newer.reload, :archived?
    refute_predicate anchor.reload, :archived?
  end

  test "bulk publish from stream returns to selected photo" do
    photo = attached_photo(title: "Publish anchor")

    post photo_bulk_actions_path, params: {
      bulk_action: "publish",
      photo_ids: [ photo.id ],
      return_to: root_path
    }

    assert_redirected_to root_path(photo_id: photo.id)
    assert_equal "Published 1 photo.", flash[:notice]
    assert_predicate photo.reload, :public?
  end

  test "bulk publish preserves search stream context" do
    photo = attached_photo(title: "Florida beach")

    post photo_bulk_actions_path, params: {
      bulk_action: "publish",
      photo_ids: [ photo.id ],
      return_to: search_path(q: "florida", cursor: "old", stream_page: 1)
    }

    assert_redirected_to search_path(q: "florida", photo_id: photo.id)
    assert_predicate photo.reload, :public?
  end

  test "bulk archive preserves search stream context after selected photos disappear" do
    first = attached_photo(title: "Florida first")
    second = attached_photo(title: "Florida second")
    anchor = attached_photo(title: "Florida anchor")
    set_stream_time(first, 3.days.ago)
    set_stream_time(second, 2.days.ago)
    set_stream_time(anchor, 1.day.ago)

    post photo_bulk_actions_path, params: {
      bulk_action: "archive",
      photo_ids: [ first.id, second.id ],
      return_to: search_path(q: "florida")
    }

    assert_redirected_to search_path(q: "florida", photo_id: anchor.id)
    assert_predicate first.reload, :archived?
    assert_predicate second.reload, :archived?
    assert_not anchor.reload.archived?
  end

  test "bulk publish preserves location stream context" do
    photo = attached_photo(title: "Location publish")
    PhotoMetadata.create!(photo: photo, latitude: 44.75, longitude: -85.60)
    location_id = PhotoLocation.id_for_coordinates(44.75, -85.60)

    post photo_bulk_actions_path, params: {
      bulk_action: "publish",
      photo_ids: [ photo.id ],
      return_to: location_path(location_id)
    }

    assert_redirected_to location_path(location_id, photo_id: photo.id)
    assert_predicate photo.reload, :public?
  end

  test "owner can move selected photos to restricted private" do
    first = attached_photo(title: "Restrict first")
    second = attached_photo(title: "Restrict second")
    first.publish!

    post photo_bulk_actions_path, params: { bulk_action: "restrict", photo_ids: [ first.id, second.id ] }

    assert_redirected_to root_path
    assert_predicate first.reload, :restricted?
    assert_predicate first, :private?
    assert_nil first.published_at
    assert_not first.archived?
    assert_predicate second.reload, :restricted?
    assert_predicate second, :private?
    assert_not second.archived?
  end

  test "bulk restrict returns near album stream position after selected photos disappear" do
    album = @owner.photo_albums.create!(title: "Trip", source: "manual")
    first = attached_photo(title: "Restrict album first")
    anchor = attached_photo(title: "Restrict album anchor")
    album.photos << [ first, anchor ]
    set_stream_time(first, 2.days.ago)
    set_stream_time(anchor, 1.day.ago)

    post photo_bulk_actions_path, params: {
      bulk_action: "restrict",
      photo_ids: [ first.id ],
      return_to: album_path(album)
    }

    assert_redirected_to album_path(album, photo_id: anchor.id)
    assert_predicate first.reload, :restricted?
    assert_not anchor.reload.restricted?
  end

  test "bulk restore returns near archived stream position" do
    first = attached_photo(title: "Restore first")
    second = attached_photo(title: "Restore second")
    anchor = attached_photo(title: "Restore anchor")
    [ first, second, anchor ].each(&:archive!)
    set_stream_time(first, 3.days.ago)
    set_stream_time(second, 2.days.ago)
    set_stream_time(anchor, 1.day.ago)

    post photo_bulk_actions_path, params: {
      bulk_action: "restore",
      photo_ids: [ first.id, second.id ],
      return_to: archived_photos_path
    }

    assert_redirected_to archived_photos_path(photo_id: anchor.id)
    assert_not first.reload.archived?
    assert_not second.reload.archived?
    assert_predicate anchor.reload, :archived?
  end

  test "bulk delete can remove archived photos and returns near archive stream position" do
    first = attached_photo(title: "Delete archived first")
    anchor = attached_photo(title: "Delete archived anchor")
    [ first, anchor ].each(&:archive!)
    set_stream_time(first, 2.days.ago)
    set_stream_time(anchor, 1.day.ago)

    assert_difference "Photo.count", -1 do
      post photo_bulk_actions_path, params: {
        bulk_action: "delete",
        photo_ids: [ first.id ],
        return_to: archived_photos_path
      }
    end

    assert_redirected_to archived_photos_path(photo_id: anchor.id)
    assert_equal anchor, Photo.find(anchor.id)
  end

  test "bulk archive ignores restricted photos" do
    photo = attached_photo(title: "Restricted")
    photo.update!(restricted: true)

    post photo_bulk_actions_path, params: { bulk_action: "archive", photo_ids: [ photo.id ] }

    assert_redirected_to root_path
    assert_not photo.reload.archived?
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

  def attached_video(title:)
    photo = @owner.photos.new(title: title)
    photo.original.attach(
      io: StringIO.new("fake mov bytes"),
      filename: "#{title.parameterize}.mov",
      content_type: "video/quicktime"
    )
    photo.save!
    photo
  end

  def set_stream_time(photo, time)
    photo.update_columns(captured_at: time, created_at: time, updated_at: time)
  end

  def stub_address_geocoder(result)
    Class.new do
      define_method(:initialize) { |geocoded| @geocoded = geocoded }
      define_method(:geocode) { |address:| @geocoded.merge(address: address) }
    end.new(result)
  end
end
