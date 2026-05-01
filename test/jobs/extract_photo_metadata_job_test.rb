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

  private

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
end
