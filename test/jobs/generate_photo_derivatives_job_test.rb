require "test_helper"

class GeneratePhotoDerivativesJobTest < ActiveJob::TestCase
  test "runs on the derivative queue" do
    assert_equal "derivatives", GeneratePhotoDerivativesJob.new.queue_name
  end

  test "generates stream and display variants" do
    photo = attached_photo

    GeneratePhotoDerivativesJob.perform_now(photo)

    assert photo.processed_original_variant_record(:stream)&.image&.attached?
    assert photo.processed_original_variant_record(:display)&.image&.attached?
  end

  test "delegates video originals to video derivative generation" do
    photo = users(:one).photos.new
    photo.original.attach(
      io: StringIO.new("fake mov bytes"),
      filename: "clip.mov",
      content_type: "video/quicktime"
    )
    photo.save!

    called_with = nil
    preview_only_value = nil
    job = GeneratePhotoDerivativesJob.new
    job.define_singleton_method(:generate_video_derivatives) do |record, preview_only: false|
      called_with = record
      preview_only_value = preview_only
    end
    job.perform(photo, preview_only: true)

    assert_equal photo, called_with
    assert_equal true, preview_only_value
  end

  test "accepts serialized preview options from solid queue" do
    photo = users(:one).photos.new
    photo.original.attach(
      io: StringIO.new("fake mov bytes"),
      filename: "clip.mov",
      content_type: "video/quicktime"
    )
    photo.save!

    preview_only_value = nil
    job = GeneratePhotoDerivativesJob.new
    job.define_singleton_method(:generate_video_derivatives) do |_record, preview_only: false|
      preview_only_value = preview_only
    end
    job.perform(photo, { "preview_only" => true })

    assert_equal true, preview_only_value
  end

  test "reports missing ffmpeg for video originals" do
    photo = users(:one).photos.new
    photo.original.attach(
      io: StringIO.new("fake mov bytes"),
      filename: "clip.mov",
      content_type: "video/quicktime"
    )
    photo.save!

    GeneratePhotoDerivativesJob.singleton_class.alias_method :original_ffmpeg_available?, :ffmpeg_available?
    GeneratePhotoDerivativesJob.define_singleton_method(:ffmpeg_available?) { false }

    begin
      error = assert_raises(RuntimeError) { GeneratePhotoDerivativesJob.perform_now(photo) }
      assert_includes error.message, "ffmpeg is required"
    ensure
      GeneratePhotoDerivativesJob.singleton_class.alias_method :ffmpeg_available?, :original_ffmpeg_available?
      GeneratePhotoDerivativesJob.singleton_class.remove_method :original_ffmpeg_available?
    end
  end

  test "falls back to a seeked frame when thumbnail filter fails" do
    photo = users(:one).photos.new
    photo.original.attach(
      io: StringIO.new("fake mov bytes"),
      filename: "clip.mov",
      content_type: "video/quicktime"
    )
    photo.save!

    calls = []
    timeouts = []
    job = GeneratePhotoDerivativesJob.new
    GeneratePhotoDerivativesJob.singleton_class.alias_method :original_ffmpeg_available?, :ffmpeg_available?
    GeneratePhotoDerivativesJob.define_singleton_method(:ffmpeg_available?) { true }
    job.define_singleton_method(:run_ffmpeg) do |*args, timeout:|
      calls << args
      timeouts << timeout
      raise "ffmpeg failed: no thumbnail" if calls.one?
    end
    job.define_singleton_method(:run_ffmpeg!) do |*args, timeout:|
      calls << args
      timeouts << timeout
    end
    job.define_singleton_method(:attach_video_preview) { |_record, _path| }

    begin
      job.generate_video_derivatives(photo, preview_only: true)
    ensure
      GeneratePhotoDerivativesJob.singleton_class.alias_method :ffmpeg_available?, :original_ffmpeg_available?
      GeneratePhotoDerivativesJob.singleton_class.remove_method :original_ffmpeg_available?
    end

    assert_equal 2, calls.size
    assert_equal [ 45.seconds, 45.seconds ], timeouts
    assert_includes calls.first, "thumbnail,scale='min(700,iw)':-2"
    assert_includes calls.second, "-ss"
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
