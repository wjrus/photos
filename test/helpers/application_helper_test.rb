require "test_helper"

class ApplicationHelperTest < ActionView::TestCase
  test "stream media does not preload original video bytes" do
    photo = attached_video

    html = photo_stream_media(photo)

    assert_includes html, "Video"
    assert_not_includes html, media_photo_path(photo)
    assert_not_includes html, "<video"
  end

  test "detail video waits for explicit playback" do
    photo = attached_video
    define_singleton_method(:current_user) { users(:one) }

    html = photo_detail_media(photo)

    assert_includes html, media_photo_path(photo)
    assert_includes html, 'preload="none"'
  end

  private

  def attached_video
    photo = users(:one).photos.new
    photo.original.attach(
      io: StringIO.new("fake mov bytes"),
      filename: "clip.mov",
      content_type: "video/quicktime"
    )
    photo.save!
    photo
  end
end
