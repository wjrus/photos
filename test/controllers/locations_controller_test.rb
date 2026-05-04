require "test_helper"

class LocationsControllerTest < ActionDispatch::IntegrationTest
  setup do
    OmniAuth.config.test_mode = true
    @owner = users(:one)
    sign_in_as(@owner)
  end

  teardown do
    OmniAuth.config.mock_auth[:google_oauth2] = nil
    OmniAuth.config.test_mode = false
  end

  test "owner can browse photo locations" do
    photo = attached_photo(title: "Downtown")
    geotag(photo, latitude: 44.7622, longitude: -85.5980)
    PhotoLocationPlace.create!(
      location_id: location_id_for(photo),
      name: "Traverse City, Michigan"
    )

    get locations_path

    assert_response :success
    assert_includes response.body, "Locations"
    assert_includes response.body, "Traverse City, Michigan"
    assert_includes response.body, "1 photo location"
    assert_includes response.body, "1 photo"
    assert_select "a[href='#{location_path(location_id_for(photo))}']"
  end

  test "location page shows matching photos as a stream" do
    inside = attached_photo(title: "Inside location")
    geotag(inside, latitude: 44.7622, longitude: -85.5980)
    PhotoLocationPlace.create!(
      location_id: location_id_for(inside),
      name: "Traverse City, Michigan"
    )
    outside = attached_photo(title: "Outside location")
    geotag(outside, latitude: 45.5, longitude: -86.5)

    get location_path(location_id_for(inside))

    assert_response :success
    assert_includes response.body, "Traverse City, Michigan"
    assert_includes response.body, "Inside location"
    refute_includes response.body, "Outside location"
    assert_select "[data-controller~='stream-state']"
  end

  test "anonymous viewer cannot browse locations" do
    delete sign_out_path

    get locations_path

    assert_redirected_to root_path
  end

  private

  def location_id_for(photo)
    metadata = photo.metadata
    PhotoLocation.id_for(
      (metadata.latitude.to_f / PhotoLocation::CELL_SIZE).floor,
      (metadata.longitude.to_f / PhotoLocation::CELL_SIZE).floor
    )
  end

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
