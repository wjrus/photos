require "test_helper"

class PhotoLocationAreasTest < ActionDispatch::IntegrationTest
  setup do
    @owner = users(:one)
    @blob = ActiveStorage::Blob.create_and_upload!(io: File.open(Rails.root.join("public/icon.png")), filename: "area.png", content_type: "image/png")
    @photos = []
    OmniAuth.config.test_mode = true
    sign_in(@owner)
  end

  teardown do
    OmniAuth.config.mock_auth[:google_oauth2] = nil
    OmniAuth.config.test_mode = false
  end

  test "a broad town card opens all its photos and shows their original points on its map" do
    first = photo("Harbor", 44.09, -87.65, town: "Manitowoc")
    second = photo("Museum", 44.15, -87.70, town: "Manitowoc")
    other = photo("Beach", 44.16, -87.59, town: "Two Rivers")
    area = PhotoLocationArea.groups(visible_scope).find { |group| group.title == "Manitowoc" }

    get locations_path(sort: "name")
    assert_response :success
    assert_select "article", count: 2
    assert_select "a[href='#{location_path(area.id)}'] h2", text: "Manitowoc"
    get location_path(area.id)
    assert_response :success
    assert_select "h1", text: "Manitowoc"
    assert_select "[data-photo-id]", count: 2
    assert_select "[data-photo-id='#{other.id}']", count: 0
    map_url = css_select("main a").find { |link| link.text.strip == "Map" }["href"]
    assert_equal area.id, Rack::Utils.parse_nested_query(URI.parse(map_url).query).fetch("location_id")

    get map_url
    assert_response :success
    assert_select "select#location_id option[selected][value='#{area.id}']"
    get map_markers_path(location_id: area.id, zoom: 18)
    payload = response.parsed_body
    assert_equal 2, payload.fetch("total")
    assert_equal [ first.id, second.id ].sort, payload.fetch("markers").map { |marker| marker.fetch("id") }.sort
    points = payload.fetch("markers").to_h { |marker| [ marker.fetch("id"), marker.values_at("latitude", "longitude") ] }
    assert_equal [ 44.09, -87.65 ], points[first.id]
    assert_equal [ 44.15, -87.70 ], points[second.id]
    refute points.key?(other.id)
  end

  test "nearby Plus Codes form one card and retain all precise markers or marker groups" do
    first = photo("2WX4+58 Grand Canyon Village", 36.0479, -112.0942)
    photo("2WX4+59 Grand Canyon Village", 36.0479, -112.0941)
    photo("2WX4+66 Grand Canyon Village", 36.0480, -112.0944)
    area = PhotoLocationArea.groups(visible_scope).sole

    get locations_path
    assert_select "article", count: 1
    assert_select "article h2", text: "Grand Canyon Village"
    get location_path(area.id)
    assert_select "[data-photo-id]", count: 3
    get map_markers_path(location_id: area.id, zoom: 18)
    payload = response.parsed_body
    assert_equal 3, payload.fetch("total")
    markers = payload.fetch("markers")
    assert_equal 3, markers.sum { |marker| marker.fetch("count") }
    assert_in_delta @photos.sum { |item| item.metadata.latitude.to_f } / 3, markers.sum { |marker| marker.fetch("latitude") * marker.fetch("count") } / 3, 0.000001
    assert_in_delta @photos.sum { |item| item.metadata.longitude.to_f } / 3, markers.sum { |marker| marker.fetch("longitude") * marker.fetch("count") } / 3, 0.000001
    get location_path(PhotoLocation.id_for_place(first.metadata.photo_place_id))
    assert_select "[data-photo-id]", count: 1
  end

  test "group pages and map extents use only the viewers visible photos even after owner cache warmup" do
    public_photo = photo("Public harbor", 44.09, -87.65, town: "Manitowoc")
    hidden = photo("Private corner", 44.5, -87.1, town: "Manitowoc")
    public_photo.publish!
    area = PhotoLocationArea.groups(visible_scope).sole
    get locations_path
    sign_in(users(:two))

    get locations_path
    assert_response :success
    assert_select "article", count: 1
    assert_includes response.body, "1 photo"
    get location_path(area.id)
    assert_select "[data-photo-id]", count: 1
    assert_select "[data-photo-id='#{hidden.id}']", count: 0
    get map_markers_path(location_id: area.id, zoom: 18)
    assert_equal 1, response.parsed_body.fetch("total")
    assert_equal public_photo.id, response.parsed_body.fetch("markers").sole.fetch("id")
    get search_path(place_id: area.id)
    assert_select "[data-photo-id]", count: 1
    assert_select "[data-photo-id='#{hidden.id}']", count: 0
  end

  test "saved area covers cannot pull a photo from another area" do
    first = photo("Harbor", 44.09, -87.65, town: "Manitowoc")
    photo("Museum", 44.10, -87.66, town: "Manitowoc")
    other = photo("Other town", 44.16, -87.59, town: "Two Rivers")
    area = PhotoLocationArea.groups(visible_scope).find { |group| group.title == "Manitowoc" }
    patch location_cover_path(area.id, other.id)
    assert_response :not_found
    patch location_cover_path(area.id, first.id)
    assert_redirected_to location_path(area.id)
    assert_equal first.id, @owner.photo_location_covers.find_by!(location_id: area.id).cover_photo_id
    get locations_path
    assert_response :success
    assert_select "article", count: 2
  end

  private

  def visible_scope
    Photo.where(id: @photos.map(&:id)).joins(:metadata)
  end

  def photo(name, latitude, longitude, town: nil)
    photo = @owner.photos.create!(title: name, original: @blob)
    photo.create_metadata!(latitude: latitude, longitude: longitude, extraction_status: "complete", raw: {})
    raw = town ? { address_components: [
      { long_name: town, types: [ "locality" ] }, { long_name: "Manitowoc County", types: [ "administrative_area_level_2" ] },
      { long_name: "Wisconsin", types: [ "administrative_area_level_1" ] }, { long_name: "United States", types: [ "country" ] }
    ] } : {}
    assign_photo_place(photo, name: name, raw: raw, place_type: town ? "premise" : "coordinate")
    @photos << photo
    photo
  end

  def sign_in(user)
    OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new(provider: user.provider, uid: user.uid, info: { email: user.email, name: user.name })
    post "/auth/google_oauth2"
    follow_redirect!
  end
end
