require "test_helper"

class LocationCoversControllerTest < ActionDispatch::IntegrationTest
  setup do
    OmniAuth.config.test_mode = true
    @owner = users(:one)
    sign_in_as(@owner)
  end

  teardown do
    OmniAuth.config.mock_auth[:google_oauth2] = nil
    OmniAuth.config.test_mode = false
  end

  test "owner can set a location cover" do
    photo = attached_photo(title: "Location cover")
    geotag(photo, latitude: 44.7622, longitude: -85.5980)
    location_id = location_id_for(photo)

    patch location_cover_path(location_id, photo)

    assert_redirected_to location_path(location_id)
    cover = @owner.photo_location_covers.find_by!(location_id: location_id)
    assert_equal photo, cover.cover_photo
  end

  test "owner can set a place location cover" do
    photo = attached_photo(title: "Place cover")
    geotag(photo, latitude: 44.7622, longitude: -85.5980)
    place_name = "Traverse City, Michigan"
    PhotoLocationPlace.create!(location_id: location_id_for(photo), name: place_name)

    patch location_cover_path(PhotoLocation.place_id_for_name(place_name), photo)

    assert_redirected_to location_path(PhotoLocation.place_id_for_name(place_name))
    cover = @owner.photo_location_covers.find_by!(location_id: PhotoLocation.place_id_for_name(place_name))
    assert_equal photo, cover.cover_photo
  end

  test "location cover photo must belong to the location" do
    inside = attached_photo(title: "Inside")
    geotag(inside, latitude: 44.7622, longitude: -85.5980)
    outside = attached_photo(title: "Outside")
    geotag(outside, latitude: 45.5, longitude: -86.5)

    patch location_cover_path(location_id_for(inside), outside)

    assert_response :not_found
    assert_empty @owner.photo_location_covers
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
