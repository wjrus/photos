require "test_helper"

class MapsControllerTest < ActionDispatch::IntegrationTest
  setup do
    OmniAuth.config.test_mode = true
    @owner = users(:one)
    @trusted_viewer_emails = ENV["PHOTOS_TRUSTED_VIEWER_EMAILS"]
    @google_maps_api_key = ENV["GOOGLE_MAPS_EMBED_API_KEY"]
    ENV["GOOGLE_MAPS_EMBED_API_KEY"] = "test-google-maps-key"
    sign_in_as(@owner)
  end

  teardown do
    ENV["PHOTOS_TRUSTED_VIEWER_EMAILS"] = @trusted_viewer_emails
    ENV["GOOGLE_MAPS_EMBED_API_KEY"] = @google_maps_api_key
    OmniAuth.config.mock_auth[:google_oauth2] = nil
    OmniAuth.config.test_mode = false
  end

  test "owner sees geotagged photos on map" do
    photo = attached_photo(title: "Northport")
    geotag(photo, latitude: 45.1317, longitude: -85.6165)

    get map_path

    assert_response :success
    assert_includes response.body, "Map"
    assert_includes response.body, "1 geotagged photo"
    assert_includes response.body, "Northport"
    assert_includes response.body, photo_path(photo, return_to: map_path)
    assert_includes response.body, "test-google-maps-key"
    assert_select "[data-controller='google-map']"
  end

  test "trusted viewer only sees public geotagged photos" do
    ENV["PHOTOS_TRUSTED_VIEWER_EMAILS"] = users(:two).email
    public_photo = attached_photo(title: "Public overlook")
    public_photo.publish!
    geotag(public_photo, latitude: 44.7622, longitude: -85.5980)
    private_photo = attached_photo(title: "Private driveway")
    geotag(private_photo, latitude: 45.0, longitude: -86.0)

    delete sign_out_path
    sign_in_as(users(:two))

    get map_path

    assert_response :success
    assert_includes response.body, "Public overlook"
    refute_includes response.body, "Private driveway"
  end

  test "anonymous viewer cannot see map" do
    delete sign_out_path

    get map_path

    assert_redirected_to root_path
  end

  test "map reports missing google maps key" do
    ENV["GOOGLE_MAPS_EMBED_API_KEY"] = nil
    photo = attached_photo(title: "Configured later")
    geotag(photo, latitude: 44.7622, longitude: -85.5980)

    get map_path

    assert_response :success
    assert_includes response.body, "Google Maps is not configured"
    assert_select "[data-controller='google-map']", false
  end

  private

  def geotag(photo, latitude:, longitude:)
    photo.create_metadata!(
      extraction_status: "complete",
      latitude: latitude,
      longitude: longitude,
      raw: {}
    )
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
