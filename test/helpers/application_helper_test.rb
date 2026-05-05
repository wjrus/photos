require "test_helper"

class ApplicationHelperTest < ActionView::TestCase
  test "stream media does not preload original video bytes" do
    photo = attached_video

    html = photo_stream_media(photo)

    assert_includes html, "Video processing"
    assert_not_includes html, media_photo_path(photo)
    assert_not_includes html, "<video"
  end

  test "stream video uses preprocessed poster" do
    photo = attached_video
    attach_video_derivatives(photo)

    html = photo_stream_media(photo)

    assert_includes html, "<img"
    assert_includes html, "clip-preview.jpg"
    assert_not_includes html, media_photo_path(photo)
    assert_not_includes html, "<video"
  end

  test "detail video uses display derivative for playback" do
    photo = attached_video
    attach_video_derivatives(photo)
    define_singleton_method(:current_user) { users(:one) }

    html = photo_detail_media(photo)

    assert_includes html, video_photo_path(photo)
    assert_includes html, 'preload="metadata"'
    assert_includes html, "clip-preview.jpg"
    assert_not_includes html, media_photo_path(photo)
  end

  test "detail video falls back to playable original while derivative processes" do
    photo = attached_video

    html = photo_detail_media(photo)

    assert_includes html, "<video"
    assert_includes html, video_photo_path(photo)
    assert_includes html, 'preload="metadata"'
    assert_not_includes html, media_photo_path(photo)
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

  test "bulk action buttons use link-like pointer cursors" do
    html = bulk_action_button(icon: :globe, label: "Publish selected photos", value: "publish")

    assert_includes html, "cursor-pointer"
    assert_includes html, "disabled:cursor-not-allowed"
  end

  test "formats video metadata" do
    metadata = PhotoMetadata.new(
      video_codec: "h264",
      audio_codec: "aac",
      video_bitrate: 8_250_000,
      video_duration: 65.432,
      video_frame_rate: 29.97
    )

    assert_equal "h264 / aac", video_codecs(metadata)
    assert_equal "8.3 Mbps", video_bitrate(metadata)
    assert_equal "1:05", video_duration(metadata)
    assert_equal "29.97 fps", video_frame_rate(metadata)
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

  def attach_video_derivatives(photo)
    photo.video_preview.attach(
      io: StringIO.new("fake jpg bytes"),
      filename: "clip-preview.jpg",
      content_type: "image/jpeg"
    )
    photo.video_display.attach(
      io: StringIO.new("fake mp4 bytes"),
      filename: "clip-display.mp4",
      content_type: "video/mp4"
    )
  end
end
