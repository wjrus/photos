require "test_helper"

class SearchControllerTest < ActionDispatch::IntegrationTest
  setup do
    OmniAuth.config.test_mode = true
    @owner = users(:one)
    sign_in_as(@owner)
  end

  teardown do
    OmniAuth.config.mock_auth[:google_oauth2] = nil
    OmniAuth.config.test_mode = false
  end

  test "search finds photos by title" do
    match = attached_photo(title: "Banff overlook")
    attached_photo(title: "Office note")

    get search_path(q: "Banff")

    assert_response :success
    assert_includes response.body, "Banff overlook"
    refute_includes response.body, "Office note"
    assert_select "a[href='#{photo_path(match)}'][data-photo-return-to='#{search_path(q: "Banff")}']"
    assert_select "form[data-controller='stream-state-reset'][data-action='submit->stream-state-reset#clear']"
  end

  test "search filters by camera and lens metadata" do
    match = attached_photo(title: "Fuji frame")
    match.create_metadata!(
      extraction_status: "complete",
      camera_make: "FUJIFILM",
      camera_model: "X100V",
      lens_model: "23mm F2",
      raw: {}
    )
    other = attached_photo(title: "Phone frame")
    other.create_metadata!(
      extraction_status: "complete",
      camera_make: "Apple",
      camera_model: "iPhone",
      lens_model: "Wide",
      raw: {}
    )

    get search_path(camera_model: "X100V", lens_model: "23mm F2")

    assert_response :success
    assert_includes response.body, "Fuji frame"
    refute_includes response.body, "Phone frame"
    assert_select "option[selected]", text: "X100V"
    assert_select "option[selected]", text: "23mm F2"
  end

  test "search finds photos by place name" do
    match = attached_photo(title: "Downtown lunch")
    match.create_metadata!(
      extraction_status: "complete",
      latitude: 44.7622,
      longitude: -85.5980,
      raw: {}
    )
    PhotoLocationPlace.create!(
      location_id: PhotoLocation.id_for_coordinates(44.7622, -85.5980),
      name: "Traverse City, Michigan"
    )
    other = attached_photo(title: "Elsewhere lunch")

    get search_path(q: "Traverse")

    assert_response :success
    assert_includes response.body, "Downtown lunch"
    refute_includes response.body, "Elsewhere lunch"
  end

  test "search finds photos by place tag hierarchy" do
    match = attached_photo(title: "Downtown lunch")
    match.create_metadata!(
      extraction_status: "complete",
      latitude: 44.7622,
      longitude: -85.5980,
      raw: {}
    )
    PhotoLocationPlace.create!(
      location_id: PhotoLocation.id_for_coordinates(44.7622, -85.5980),
      name: "Traverse City, Michigan",
      names: [ "Traverse City, Michigan", "Traverse City", "Michigan", "United States" ]
    )
    other = attached_photo(title: "Elsewhere lunch")

    get search_path(q: "United States")

    assert_response :success
    assert_includes response.body, "Downtown lunch"
    refute_includes response.body, "Elsewhere lunch"
  end

  private

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
