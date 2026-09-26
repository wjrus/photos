require "test_helper"

class SearchLocationFilterTest < ActionDispatch::IntegrationTest
  setup do
    OmniAuth.config.test_mode = true
    owner = users(:one)
    OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new(
      provider: owner.provider, uid: owner.uid,
      info: { email: owner.email, name: owner.name, image: owner.avatar_url }
    )
    post "/auth/google_oauth2"
    follow_redirect!

    now = Time.current
    @photos = Photo.insert_all!(3.times.map do |index|
      { owner_id: owner.id, title: "Boundary image #{index}", created_at: now, updated_at: now }
    end).rows.flatten
    PhotoMetadata.insert_all!([ "44.774999", "44.775000", "44.775001" ].each_with_index.map do |latitude, index|
      { photo_id: @photos[index], latitude: latitude, longitude: "-85.575000", created_at: now, updated_at: now }
    end)
    PhotoLocationPlace.create!(location_id: "1790_-3423", name: "Synthetic boundary place")
  end

  teardown do
    OmniAuth.config.mock_auth[:google_oauth2] = nil
    OmniAuth.config.test_mode = false
  end

  test "named place menu and text search include boundary photos in their persisted location" do
    get search_path
    assert_response :success
    place_id = css_select("select#place_id option").find { |option| option.text == "Synthetic boundary place" }&.[]("value")
    assert_equal PhotoLocation.place_id_for_name("Synthetic boundary place"), place_id

    [ { place_id: place_id }, { q: "Synthetic boundary place" } ].each do |filters|
      get search_path(filters)
      assert_response :success
      @photos.first(2).each { |id| assert_select "[data-photo-id='#{id}']" }
      assert_select "[data-photo-id='#{@photos.last}']", count: 0
    end
  end

  test "place menu excludes names found only through a missing coordinate" do
    [ [ 30, nil, "1200_0" ], [ nil, 30, "0_1200" ] ].each_with_index do |(latitude, longitude, location_id), index|
      photo = Photo.find(@photos[index])
      photo.metadata.update!(latitude: latitude, longitude: longitude)
      PhotoLocationPlace.create!(location_id: location_id, name: "Incomplete location #{index}")
    end

    get search_path

    assert_response :success
    assert_select "select#place_id option", text: /Incomplete location/, count: 0
  end
end
