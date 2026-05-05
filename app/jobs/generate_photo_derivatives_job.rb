require "open3"
require "tmpdir"

class GeneratePhotoDerivativesJob < ApplicationJob
  queue_as :derivatives

  IMAGE_DERIVATIVES = %i[stream display].freeze
  VIDEO_PREVIEW_SIZE = 700
  VIDEO_DISPLAY_SIZE = 1800
  VIDEO_PREVIEW_TIMEOUT = 45.seconds
  VIDEO_DISPLAY_TIMEOUT = 30.minutes
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

    Rails.logger.info(
      "Generating video #{preview_only ? 'preview' : 'derivatives'} for photo #{photo.id} " \
      "(#{photo.original_filename}, #{photo.original.blob.byte_size} bytes)"
    )

    photo.original.open do |original_file|
      Dir.mktmpdir("photo-video-derivatives") do |dir|
        preview_path = File.join(dir, "preview.jpg")
        display_path = File.join(dir, "display.mp4")

        unless photo.video_preview.attached?
          Rails.logger.info("Generating video preview frame for photo #{photo.id}")
          generate_video_preview_file(original_file.path, preview_path)
          attach_video_preview(photo, preview_path)
          Rails.logger.info("Attached video preview frame for photo #{photo.id}")
        end

        next if preview_only || photo.video_display.attached?

        Rails.logger.info("Generating video display derivative for photo #{photo.id}")
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
          display_path,
          timeout: VIDEO_DISPLAY_TIMEOUT
        )

        attach_video_display(photo, display_path)
        Rails.logger.info("Attached video display derivative for photo #{photo.id}")
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

  def generate_video_preview_file(original_path, preview_path)
    run_ffmpeg(
      "-i", original_path,
      "-vf", "thumbnail,scale='min(#{VIDEO_PREVIEW_SIZE},iw)':-2",
      "-frames:v", "1",
      preview_path,
      timeout: VIDEO_PREVIEW_TIMEOUT
    )
  rescue RuntimeError => error
    Rails.logger.warn("Video thumbnail filter failed, falling back to seeked frame: #{error.message}")
    File.delete(preview_path) if File.exist?(preview_path)

    run_ffmpeg!(
      "-ss", "1",
      "-i", original_path,
      "-vf", "scale='min(#{VIDEO_PREVIEW_SIZE},iw)':-2",
      "-frames:v", "1",
      preview_path,
      timeout: VIDEO_PREVIEW_TIMEOUT
    )
  end

  def video_derivative_basename(photo)
    File.basename(photo.original_filename.to_s.presence || "video", ".*").parameterize.presence || "video"
  end

  def run_ffmpeg(*args, timeout:)
    stdout = +""
    stderr = +""
    status = nil

    Open3.popen3(FFMPEG, "-y", "-hide_banner", "-loglevel", "error", *args) do |stdin, stdout_io, stderr_io, wait_thread|
      stdin.close
      stdout_reader = Thread.new { stdout_io.read.to_s }
      stderr_reader = Thread.new { stderr_io.read.to_s }

      unless wait_thread.join(timeout)
        terminate_ffmpeg(wait_thread.pid)
        wait_thread.join
        stdout = stdout_reader.value
        stderr = stderr_reader.value
        raise "ffmpeg timed out after #{timeout.to_i}s: #{stderr.presence || stdout.presence || 'no output'}"
      end

      stdout = stdout_reader.value
      stderr = stderr_reader.value
      status = wait_thread.value
    end

    return if status.success?

    raise "ffmpeg failed: #{stderr.presence || stdout.presence || 'unknown error'}"
  end

  def run_ffmpeg!(*args, timeout:)
    run_ffmpeg(*args, timeout: timeout)
  end

  def terminate_ffmpeg(pid)
    Process.kill("TERM", pid)
    sleep 1
    Process.kill("KILL", pid)
  rescue Errno::ESRCH, Errno::ECHILD
  end
end
