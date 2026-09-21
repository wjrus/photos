require "test_helper"

class PhotoStreamPaginationTest < ActionDispatch::IntegrationTest
  setup do
    owner = users(:one)
    owner.update!(password: "password12")
    post sign_in_path, params: { email: owner.email, password: "password12" }

    blob = ActiveStorage::Blob.create_and_upload!(
      io: File.open(Rails.root.join("public/icon.png")),
      filename: "pagination-photo.png",
      content_type: "image/png"
    )
    @photos = (Photo::STREAM_PAGE_SIZE * 2 + 3).times.map do |index|
      Photo.create!(
        title: "Pagination photo #{index}", owner: owner, original: blob, visibility: "public",
        captured_at: (Time.zone.local(2024, 1, 1) if index <= Photo::STREAM_PAGE_SIZE),
        created_at: Time.zone.local(2024, 2, 1)
      )
    end
    @album = owner.photo_albums.create!(title: "Pagination album", source: "manual")
    @album.photos << @photos
    @photos.each { |photo| photo.create_metadata!(extraction_status: "complete", latitude: 40, longitude: -80, raw: {}) }
  end

  %w[home album public archive location search].each do |stream|
    [ false, true ].each do |focused|
      test "#{stream} pagination includes every photo in order#{' after returning from the viewer' if focused}" do
        path = stream_path(stream)
        ordered_photos = ordered_photos(stream)
        expected = focused ? ordered_photos.drop(1) : ordered_photos
        get path, params: (focused ? { photo_id: expected.first.id } : {})

        ids = []
        loop do
          assert_response :success
          ids.concat(response.parsed_body.css("[data-photo-id]").map { |card| card["data-photo-id"].to_i })
          next_page = response.parsed_body.at_css("[data-infinite-scroll-target='sentinel']:not([data-stream-page-direction='newer'])")
          break unless next_page

          assert_operator ids.size, :<, expected.size
          get next_page["data-next-url"]
        end

        assert_equal expected.map(&:id), ids
      end
    end
  end

  %w[home album public archive location search].each do |stream|
    test "#{stream} backward pagination includes timestamp ties and undated photos exactly once" do
      path = stream_path(stream)
      expected = ordered_photos(stream)
      get path, params: { photo_id: expected.last.id }

      ids = []
      loop do
        assert_response :success
        ids.prepend(*response.parsed_body.css("[data-photo-id]").map { |card| card["data-photo-id"].to_i })
        previous_page = response.parsed_body.at_css("[data-stream-page-direction='newer']")
        break unless previous_page

        assert_operator ids.size, :<, expected.size
        get previous_page["data-next-url"]
      end

      assert_equal expected.map(&:id), ids
    end
  end

  test "timeline jumps exclude photos exactly at the next period boundary" do
    boundary = Time.zone.local(2024, 2, 1)
    @photos.first.update!(captured_at: boundary)

    get root_path(cursor: Photo.stream_cursor_before(boundary), stream_page: 1, timeline_page: 1)

    assert_response :success
    assert_select "[data-photo-id='#{@photos.first.id}']", count: 0
    assert_select "[data-photo-id='#{@photos.second.id}']"
  end

  private

  def stream_path(stream)
    case stream
    when "home" then root_path
    when "album" then album_path(@album)
    when "public" then public_photos_path
    when "archive"
      Photo.where(id: @photos.map(&:id)).update_all(archived_at: Time.current)
      archived_photos_path
    when "location" then location_path(PhotoLocation.id_for_coordinates(40, -80))
    when "search" then search_path(q: "Pagination photo")
    end
  end

  def ordered_photos(stream)
    dated, undated = @photos.partition(&:captured_at)
    stream == "album" ? dated + undated : dated.reverse + undated.reverse
  end
end
