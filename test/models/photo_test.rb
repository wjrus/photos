require "test_helper"

class PhotoTest < ActiveSupport::TestCase
  test "new photos default to private" do
    photo = users(:one).photos.new

    assert_equal "private", photo.visibility
  end

  test "copies original blob attributes" do
    photo = users(:one).photos.new
    photo.original.attach(
      io: File.open(Rails.root.join("public/icon.png")),
      filename: "summer-road.png",
      content_type: "image/png"
    )

    assert_predicate photo, :valid?
    assert_equal "summer-road.png", photo.original_filename
    assert_equal "image/png", photo.content_type
    assert_equal "Summer road", photo.title
  end

  test "accepts video originals" do
    photo = users(:one).photos.new
    photo.original.attach(
      io: StringIO.new("fake mov bytes"),
      filename: "clip.mov",
      content_type: "video/quicktime"
    )

    assert_predicate photo, :valid?
    assert_predicate photo, :video?
    assert_equal "Clip", photo.title
  end

  test "accepts heic originals" do
    photo = users(:one).photos.new
    photo.original.attach(
      io: StringIO.new("fake heic bytes"),
      filename: "portrait.HEIC",
      content_type: "image/heic"
    )

    assert_predicate photo, :valid?
    assert_predicate photo, :image?
    assert_equal "Portrait", photo.title
  end

  test "preserves aae sidecars with originals" do
    photo = users(:one).photos.new
    photo.original.attach(
      io: File.open(Rails.root.join("public/icon.png")),
      filename: "portrait.png",
      content_type: "image/png"
    )
    photo.sidecars.attach(
      io: StringIO.new("<?xml version=\"1.0\"?>"),
      filename: "portrait.AAE",
      content_type: "application/xml"
    )

    assert_predicate photo, :valid?
    assert_equal 1, photo.sidecar_count
  end

  test "rejects non aae sidecars" do
    photo = users(:one).photos.new
    photo.original.attach(
      io: File.open(Rails.root.join("public/icon.png")),
      filename: "portrait.png",
      content_type: "image/png"
    )
    photo.sidecars.attach(
      io: StringIO.new("not a sidecar"),
      filename: "notes.txt",
      content_type: "text/plain"
    )

    assert_not photo.valid?
    assert_includes photo.errors[:sidecars], "must be Apple .AAE sidecar files"
  end

  test "enqueues checksum job after create" do
    assert_enqueued_with(job: ChecksumOriginalJob) do
      attached_photo
    end
  end

  test "enqueues metadata extraction job after create" do
    assert_enqueued_with(job: ExtractPhotoMetadataJob) do
      attached_photo
    end
  end

  test "publishes and unpublishes" do
    photo = attached_photo

    photo.publish!
    assert_predicate photo, :public?
    assert_predicate photo.published_at, :present?

    photo.unpublish!
    assert_predicate photo, :private?
    assert_nil photo.published_at
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
end
