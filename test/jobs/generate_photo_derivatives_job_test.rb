require "test_helper"

class GeneratePhotoDerivativesJobTest < ActiveJob::TestCase
  test "generates stream and display variants" do
    photo = attached_photo

    GeneratePhotoDerivativesJob.perform_now(photo)

    assert photo.processed_original_variant_record(:stream)&.image&.attached?
    assert photo.processed_original_variant_record(:display)&.image&.attached?
  end

  test "ignores video originals" do
    photo = users(:one).photos.new
    photo.original.attach(
      io: StringIO.new("fake mov bytes"),
      filename: "clip.mov",
      content_type: "video/quicktime"
    )
    photo.save!

    assert_nothing_raised do
      GeneratePhotoDerivativesJob.perform_now(photo)
    end
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
