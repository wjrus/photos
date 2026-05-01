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
