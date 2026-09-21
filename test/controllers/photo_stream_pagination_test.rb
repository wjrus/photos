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
    @photos = (Photo::STREAM_PAGE_SIZE + 2).times.map do |index|
      Photo.create!(title: "Pagination photo #{index}", owner: owner, captured_at: Time.zone.local(2024, 1, 1) + index.hours, original: blob)
    end
    @album = owner.photo_albums.create!(title: "Pagination album", source: "manual")
    @album.photos << @photos
  end

  %w[home album].each do |stream|
    [ false, true ].each do |focused|
      test "#{stream} pagination includes every photo in order#{' after returning from the viewer' if focused}" do
        path = stream == "home" ? root_path : album_path(@album)
        ordered_photos = stream == "home" ? @photos.reverse : @photos
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
end
