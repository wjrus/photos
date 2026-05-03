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

  test "stream image waits for preprocessed thumbnail" do
    photo = attached_photo

    html = photo_stream_media(photo)

    assert_includes html, "Processing"
    assert_not_includes html, display_photo_path(photo)
  end

  test "detail image waits for a preprocessed derivative" do
    photo = attached_photo

    html = photo_detail_media(photo)

    assert_includes html, "Image derivative processing"
    assert_not_includes html, display_photo_path(photo)
  end

  private

  def attached_photo
    photo = users(:one).photos.new
    photo.original.attach(
      io: File.open(Rails.root.join("public/icon.png")),
      filename: "fixture.png",
      content_type: "image/png"
    )
    photo.save!
    photo
  end

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
