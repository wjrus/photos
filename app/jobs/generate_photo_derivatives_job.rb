require "open3"
require "tmpdir"

class GeneratePhotoDerivativesJob < ApplicationJob
  queue_as :derivatives

  IMAGE_DERIVATIVES = %i[stream display].freeze
  VIDEO_PREVIEW_SIZE = 700
  VIDEO_DISPLAY_SIZE = 1800
  FFMPEG = "ffmpeg".freeze

  def perform(photo, options = {})
    return unless photo.original.attached?

    preview_only = options.fetch(:preview_only, options.fetch("preview_only", false))

    if photo.image?
      generate_image_derivatives(photo)
    elsif photo.video?
      generate_video_derivatives(photo, preview_only: preview_only)
    end
  end

  def generate_image_derivatives(photo)
    IMAGE_DERIVATIVES.each do |variant_name|
      photo.original.variant(variant_name).processed
    end
  end

  def generate_video_derivatives(photo, preview_only: false)
    return if preview_only ? photo.video_preview.attached? : photo.video_derivatives_ready?

    raise "ffmpeg is required to generate video derivatives" unless self.class.ffmpeg_available?

    photo.original.open do |original_file|
      Dir.mktmpdir("photo-video-derivatives") do |dir|
        preview_path = File.join(dir, "preview.jpg")
        display_path = File.join(dir, "display.mp4")

        unless photo.video_preview.attached?
          run_ffmpeg!(
            "-i", original_file.path,
            "-vf", "thumbnail,scale='min(#{VIDEO_PREVIEW_SIZE},iw)':-2",
            "-frames:v", "1",
            preview_path
          )
          attach_video_preview(photo, preview_path)
        end

        next if preview_only || photo.video_display.attached?

        run_ffmpeg!(
          "-i", original_file.path,
          "-map", "0:v:0",
          "-map", "0:a?",
          "-vf", "scale='min(#{VIDEO_DISPLAY_SIZE},iw)':-2",
          "-c:v", "libx264",
          "-preset", "veryfast",
          "-crf", "23",
          "-pix_fmt", "yuv420p",
          "-c:a", "aac",
          "-b:a", "128k",
          "-movflags", "+faststart",
          display_path
        )

        attach_video_display(photo, display_path)
      end
    end
  end

  def self.ffmpeg_available?
    system(FFMPEG, "-version", out: File::NULL, err: File::NULL)
  end

  private

  def attach_video_preview(photo, preview_path)
    photo.video_preview.attach(
      io: File.open(preview_path, "rb"),
      filename: "#{video_derivative_basename(photo)}-preview.jpg",
      content_type: "image/jpeg"
    )
  end

  def attach_video_display(photo, display_path)
    photo.video_display.attach(
      io: File.open(display_path, "rb"),
      filename: "#{video_derivative_basename(photo)}-display.mp4",
      content_type: "video/mp4"
    )
  end

  def video_derivative_basename(photo)
    File.basename(photo.original_filename.to_s.presence || "video", ".*").parameterize.presence || "video"
  end

  def run_ffmpeg!(*args)
    stdout, stderr, status = Open3.capture3(FFMPEG, "-y", "-hide_banner", "-loglevel", "error", *args)
    return if status.success?

    raise "ffmpeg failed: #{stderr.presence || stdout.presence || 'unknown error'}"
  end
end
