require "test_helper"

class AggregateCacheAccessTest < ActionDispatch::IntegrationTest
  setup do
    @previous_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    OmniAuth.config.test_mode = true
    @previous_maps_key = ENV["GOOGLE_MAPS_EMBED_API_KEY"]
    ENV["GOOGLE_MAPS_EMBED_API_KEY"] = "test-google-maps-key"
    @owner = users(:one)
    @viewer = users(:two)
    @photo = @owner.photos.create!(
      title: "Private overlook",
      captured_at: Time.zone.local(2024, 5, 10, 12),
      original: {
        io: File.open(Rails.root.join("public/icon.png")),
        filename: "private-overlook.png",
        content_type: "image/png"
      }
    )
    @photo.create_metadata!(extraction_status: "complete", latitude: 44.76, longitude: -85.59, raw: {})
    @place = PhotoLocationPlace.create!(
      location_id: PhotoLocation.id_for_coordinates(44.76, -85.59),
      name: "Private valley"
    )
    @album = @owner.photo_albums.create!(title: "Public album", source: "manual", visibility: "public")
    sign_in_as(@viewer)
  end

  teardown do
    Rails.cache = @previous_cache
    ENV["GOOGLE_MAPS_EMBED_API_KEY"] = @previous_maps_key
    OmniAuth.config.mock_auth[:google_oauth2] = nil
    OmniAuth.config.test_mode = false
  end

  %i[people_tag album_membership].each do |grant_kind|
    test "map markers exclude private metadata immediately after #{grant_kind} revocation" do
      prepare_grant(grant_kind)
      grant = create_grant(grant_kind)
      assert_map_photo_count(1)

      grant.destroy!

      assert_map_photo_count(0)
      assert_empty response.parsed_body.fetch("markers")
      refute_includes response.body, @photo.title
    end

    test "locations exclude private metadata immediately after #{grant_kind} revocation" do
      prepare_grant(grant_kind)
      grant = create_grant(grant_kind)
      assert_location_count(1)

      grant.destroy!

      assert_location_count(0)
      refute_includes response.body, @place.name
    end

    test "map markers include newly granted #{grant_kind} access despite a warm cache" do
      prepare_grant(grant_kind)
      assert_map_photo_count(0)

      create_grant(grant_kind)

      assert_map_photo_count(1)
      assert_equal @photo.title, response.parsed_body.fetch("markers").sole.fetch("title")
    end

    test "locations include newly granted #{grant_kind} access despite a warm cache" do
      prepare_grant(grant_kind)
      assert_location_count(0)

      create_grant(grant_kind)

      assert_location_count(1)
    end
  end

  test "home timeline removes private dates after people tag revocation" do
    create_public_background_photo
    grant = create_grant(:people_tag)
    get root_path
    assert_response :success
    assert_select "[data-stream-timeline-period-key-value^='2024']"

    grant.destroy!

    get root_path
    assert_response :success
    assert_select "[data-stream-timeline-period-key-value^='2024']", count: 0
    assert_select "[data-photo-id='#{@photo.id}']", count: 0
  end

  test "public album counts remove private photos after people tag revocation" do
    @album.photo_album_memberships.create!(photo: @photo)
    grant = create_grant(:people_tag)
    get albums_path
    assert_response :success
    assert_select "article", text: /Public album.*1 photo/m

    grant.destroy!

    get albums_path
    assert_response :success
    assert_select "article", text: /Public album.*0 photos/m
  end

  %i[unpublish! restrict!].each do |transition|
    test "anonymous aggregates drop photo metadata immediately after #{transition}" do
      freeze_time do
        @photo.publish!
        create_public_background_photo
        @album.photo_album_memberships.create!(photo: @photo)
        delete sign_out_path
        get root_path
        assert_response :success
        assert_select "[data-stream-timeline-period-key-value^='2024']"
        get albums_path
        assert_response :success
        assert_select "article", text: /Public album.*1 photo/m

        @photo.public_send(transition)

        get root_path
        assert_response :success
        assert_select "[data-stream-timeline-period-key-value^='2024']", count: 0
        assert_select "[data-photo-id='#{@photo.id}']", count: 0
        get albums_path
        assert_response :success
        assert_select "article", text: /Public album.*0 photos/m
      end
    end
  end

  test "viewer map bounds exclude hidden photos in the same named place" do
    create_grant(:people_tag)
    hidden = @owner.photos.create!(title: "Hidden faraway photo", original: @photo.original.blob)
    hidden.create_metadata!(extraction_status: "complete", latitude: 50, longitude: -70, raw: {})
    PhotoLocationPlace.create!(
      location_id: PhotoLocation.id_for_coordinates(50, -70), name: @place.name
    )
    PhotoLocationBound.refresh_all!
    location_id = PhotoLocation.place_id_for_name(@place.name)

    get map_path(location_id: location_id)

    assert_response :success
    assert_select "[data-google-map-initial-north-value='44.800000']"
    assert_select "[data-google-map-initial-south-value='44.720000']"
    assert_select "[data-google-map-initial-east-value='-85.550000']"
    assert_select "[data-google-map-initial-west-value='-85.630000']"

    sign_in_as(@owner)
    get map_path(location_id: location_id)
    assert_response :success
    PhotoLocationBound.find_by!(location_id: location_id).padded_bounds.each do |direction, value|
      assert_select "[data-google-map-initial-#{direction}-value='#{format('%.6f', value)}']"
    end
  end

  private

  def create_public_background_photo
    @owner.photos.create!(
      title: "Public older photo", visibility: "public", captured_at: Time.zone.local(2022, 1, 1, 12),
      original: @photo.original.blob
    )
  end

  def prepare_grant(kind)
    return unless kind == :album_membership

    @album.photo_album_shares.create!(user: @viewer, shared_by: @owner)
  end

  def create_grant(kind)
    if kind == :people_tag
      @photo.photo_people_tags.create!(user: @viewer, tagged_by: @owner)
    else
      @album.photo_album_memberships.create!(photo: @photo)
    end
  end

  def assert_map_photo_count(count)
    get map_markers_path
    assert_response :success
    assert_equal count, response.parsed_body.fetch("total")
  end

  def assert_location_count(count)
    get locations_path
    assert_response :success
    assert_select "article", count: count
    assert_includes response.body, @place.name if count.positive?
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
