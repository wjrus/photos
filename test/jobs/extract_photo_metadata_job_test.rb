require "test_helper"

class ExtractPhotoMetadataJobTest < ActiveJob::TestCase
  test "marks unsupported originals without exposing raw metadata" do
    photo = attached_png

    ExtractPhotoMetadataJob.perform_now(photo)

    metadata = photo.reload.metadata
    assert_equal "unsupported", metadata.extraction_status
    assert_equal({}, metadata.raw)
    assert_predicate metadata.extracted_at, :present?
  end

  test "marks video originals unsupported for exif extraction" do
    photo = attached_video

    ExtractPhotoMetadataJob.perform_now(photo)

    metadata = photo.reload.metadata
    assert_equal "unsupported", metadata.extraction_status
    assert_equal({}, metadata.raw)
  end

  test "extracts heic-style exif from vips metadata" do
    photo = attached_png
    image = FakeVipsImage.new(
      "exif-ifd0-Make" => "Apple (Apple, ASCII, 6 components, 6 bytes)",
      "exif-ifd0-Model" => "iPhone 17 Pro Max (iPhone 17 Pro Max, ASCII, 18 components, 18 bytes)",
      "exif-ifd2-DateTimeOriginal" => "2026:03:22 10:58:00 (2026:03:22 10:58:00, ASCII, 20 components, 20 bytes)",
      "exif-ifd2-ExposureTime" => "1/906 (1/906 sec., Rational, 1 components, 8 bytes)",
      "exif-ifd2-FNumber" => "1244236/699009 (f/1.8, Rational, 1 components, 8 bytes)",
      "exif-ifd2-FocalLength" => "251773/37217 (6.8 mm, Rational, 1 components, 8 bytes)",
      "exif-ifd2-ISOSpeedRatings" => "64 (64, Short, 1 components, 2 bytes)",
      "exif-ifd2-LensModel" => "iPhone 17 Pro Max back triple camera 6.765mm f/1.78 (iPhone 17 Pro Max back triple camera 6.765mm f/1.78, ASCII, 52 components, 52 bytes)",
      "exif-ifd3-GPSLatitude" => "44/1 45/1 4400/100 (44, 45, 44.00, Rational, 3 components, 24 bytes)",
      "exif-ifd3-GPSLatitudeRef" => "N (N, ASCII, 2 components, 2 bytes)",
      "exif-ifd3-GPSLongitude" => "85/1 35/1 5274/100 (85, 35, 52.74, Rational, 3 components, 24 bytes)",
      "exif-ifd3-GPSLongitudeRef" => "W (W, ASCII, 2 components, 2 bytes)"
    )

    job = ExtractPhotoMetadataJob.new
    job.define_singleton_method(:vips_image) { |_path| image }
    job.perform(photo)

    metadata = photo.reload.metadata
    assert_equal "complete", metadata.extraction_status
    assert_equal Time.zone.local(2026, 3, 22, 10, 58), metadata.captured_at
    assert_equal metadata.captured_at, photo.captured_at
    assert_equal "Apple", metadata.camera_make
    assert_equal "iPhone 17 Pro Max", metadata.camera_model
    assert_equal "iPhone 17 Pro Max back triple camera 6.765mm f/1.78", metadata.lens_model
    assert_equal 64, metadata.iso
    assert_equal "f/1.8", metadata.aperture
    assert_equal "1/906 sec.", metadata.exposure_time
    assert_equal "6.8 mm", metadata.focal_length
    assert_in_delta 44.762222, metadata.latitude.to_f, 0.000001
    assert_in_delta(-85.597983, metadata.longitude.to_f, 0.000001)
  end

  private

  class FakeVipsImage
    def initialize(fields)
      @fields = fields
    end

    def get_fields
      @fields.keys
    end

    def get(field)
      @fields.fetch(field)
    end
  end

  def attached_png
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
