require "test_helper"

class GenerateVideoPreviewJobTest < ActiveJob::TestCase
  test "runs on the video preview queue" do
    assert_equal "video_previews", GenerateVideoPreviewJob.new.queue_name
  end

  test "delegates to thumbnail-only derivative generation" do
    photo = users(:one).photos.new
    photo.original.attach(
      io: StringIO.new("fake mov bytes"),
      filename: "clip.mov",
      content_type: "video/quicktime"
    )
    photo.save!

    called_with = nil
    GeneratePhotoDerivativesJob.singleton_class.alias_method :original_perform_now, :perform_now
    GeneratePhotoDerivativesJob.define_singleton_method(:perform_now) do |record, preview_only: false|
      called_with = [ record, preview_only ]
    end

    GenerateVideoPreviewJob.perform_now(photo)

    assert_equal [ photo, true ], called_with
  ensure
    GeneratePhotoDerivativesJob.singleton_class.alias_method :perform_now, :original_perform_now
    GeneratePhotoDerivativesJob.singleton_class.remove_method :original_perform_now
  end
end
