require "json"
require "open3"
require "vips"

class ExtractPhotoMetadataJob < ApplicationJob
  queue_as :maintenance

  def perform(photo)
    metadata = PhotoMetadata.for_photo(photo)

    unless photo.original.attached?
      metadata.update!(extraction_status: "failed", extraction_error: "Original is not attached", extracted_at: Time.current)
      return
    end

    if photo.video?
      extract_video_metadata(photo, metadata)
      return
    end

    unless photo.image?
      clear_media_metadata(metadata, extraction_status: "unsupported", raw: {})
      return
    end

    photo.original.blob.open do |file|
      image = vips_image(file.path)
      exif = extract_exif(image)
      dimensions = image_dimensions(image)

      unless exif.any?
        metadata.update!(
          extraction_status: "unsupported",
          extraction_error: nil,
          raw: {},
          width: dimensions[:width],
          height: dimensions[:height],
          video_codec: nil,
          video_profile: nil,
          audio_codec: nil,
          video_container: nil,
          video_bitrate: nil,
          video_duration: nil,
          video_frame_rate: nil,
          extracted_at: Time.current
        )
        return
      end

      captured_at = parse_captured_at(exif["DateTimeOriginal"] || exif["DateTime"])

      metadata.update!(
        extraction_status: "complete",
        extraction_error: nil,
        captured_at: captured_at,
        camera_make: exif["Make"],
        camera_model: exif["Model"],
        lens_model: exif["LensModel"],
        iso: exif["ISOSpeedRatings"]&.to_i,
        aperture: exif["FNumber"],
        exposure_time: exif["ExposureTime"],
        focal_length: exif["FocalLength"],
        latitude: gps_coordinate(exif["GPSLatitude"], exif["GPSLatitudeRef"]),
        longitude: gps_coordinate(exif["GPSLongitude"], exif["GPSLongitudeRef"]),
        width: dimensions[:width],
        height: dimensions[:height],
        video_codec: nil,
        video_profile: nil,
        audio_codec: nil,
        video_container: nil,
        video_bitrate: nil,
        video_duration: nil,
        video_frame_rate: nil,
        raw: exif,
        extracted_at: Time.current
      )
      photo.update_columns(captured_at: captured_at, updated_at: Time.current) if captured_at
    end
  rescue StandardError => e
    PhotoMetadata.for_photo(photo).update!(
      extraction_status: "failed",
      extraction_error: e.message,
      extracted_at: Time.current
    )
    raise
  end

  private

  def extract_video_metadata(photo, metadata)
    photo.original.blob.open do |file|
      probe = ffprobe_metadata(file.path)
      format = probe.fetch("format", {})
      video_stream = streams(probe).find { |stream| stream["codec_type"] == "video" }
      audio_stream = streams(probe).find { |stream| stream["codec_type"] == "audio" }
      captured_at = parse_video_captured_at(format, video_stream)

      metadata.update!(
        extraction_status: "complete",
        extraction_error: nil,
        captured_at: captured_at,
        width: integer_value(video_stream&.fetch("width", nil)),
        height: integer_value(video_stream&.fetch("height", nil)),
        video_codec: video_stream&.fetch("codec_name", nil),
        video_profile: video_stream&.fetch("profile", nil),
        audio_codec: audio_stream&.fetch("codec_name", nil),
        video_container: format["format_long_name"].presence || format["format_name"],
        video_bitrate: integer_value(format["bit_rate"]) || integer_value(video_stream&.fetch("bit_rate", nil)),
        video_duration: decimal_value(format["duration"]) || decimal_value(video_stream&.fetch("duration", nil)),
        video_frame_rate: frame_rate(video_stream&.fetch("avg_frame_rate", nil) || video_stream&.fetch("r_frame_rate", nil)),
        raw: probe,
        extracted_at: Time.current
      )
      photo.update_columns(captured_at: captured_at, updated_at: Time.current) if captured_at
    end
  end

  def ffprobe_metadata(path)
    stdout, stderr, status = Open3.capture3(
      "ffprobe",
      "-v", "error",
      "-print_format", "json",
      "-show_format",
      "-show_streams",
      path
    )
    raise "ffprobe failed: #{stderr.presence || stdout.presence || 'unknown error'}" unless status.success?

    JSON.parse(stdout)
  end

  def extract_exif(image)
    image.get_fields.filter_map do |field|
      next unless field.start_with?("exif-ifd")

      [ exif_key(field), clean_exif_value(field, image.get(field).to_s) ]
    end.to_h.compact_blank
  end

  def vips_image(path)
    Vips::Image.new_from_file(path, access: :sequential)
  end

  def image_dimensions(image)
    { width: image.width, height: image.height }
  end

  def exif_key(field)
    field.split("-", 3).last
  end

  def clean_exif_value(field, value)
    if field.match?(/-(FNumber|ExposureTime|FocalLength)\z/)
      display_exif_value(value) || raw_exif_value(value)
    else
      raw_exif_value(value)
    end
  end

  def raw_exif_value(value)
    value.split(" (", 2).first.presence
  end

  def display_exif_value(value)
    value[/\(([^,]+),/, 1].presence
  end

  def parse_captured_at(value)
    return if value.blank?

    Time.zone.strptime(value, "%Y:%m:%d %H:%M:%S")
  rescue ArgumentError
    nil
  end

  def parse_video_captured_at(format, video_stream)
    creation_time = format.dig("tags", "creation_time") || video_stream&.dig("tags", "creation_time")
    return if creation_time.blank?

    Time.zone.parse(creation_time)
  rescue ArgumentError
    nil
  end

  def streams(probe)
    Array(probe["streams"])
  end

  def integer_value(value)
    return if value.blank? || value == "N/A"

    value.to_i
  end

  def decimal_value(value)
    return if value.blank? || value == "N/A"

    BigDecimal(value.to_s)
  rescue ArgumentError
    nil
  end

  def frame_rate(value)
    return if value.blank? || value == "0/0" || value == "N/A"

    numerator, denominator = value.split("/", 2).map(&:to_d)
    return numerator unless denominator
    return if denominator.zero?

    numerator / denominator
  end

  def clear_media_metadata(metadata, attributes)
    metadata.update!(
      {
        extraction_error: nil,
        captured_at: nil,
        camera_make: nil,
        camera_model: nil,
        lens_model: nil,
        iso: nil,
        aperture: nil,
        exposure_time: nil,
        focal_length: nil,
        latitude: nil,
        longitude: nil,
        width: nil,
        height: nil,
        video_codec: nil,
        video_profile: nil,
        audio_codec: nil,
        video_container: nil,
        video_bitrate: nil,
        video_duration: nil,
        video_frame_rate: nil,
        extracted_at: Time.current
      }.merge(attributes)
    )
  end

  def gps_coordinate(value, reference)
    return if value.blank? || reference.blank?

    degrees, minutes, seconds = value.split.first(3).map { |component| rational_value(component) }
    coordinate = degrees + (minutes / 60) + (seconds / 3600)
    reference.in?(%w[S W]) ? -coordinate : coordinate
  end

  def rational_value(value)
    numerator, denominator = value.split("/", 2)
    return numerator.to_d unless denominator

    numerator.to_d / denominator.to_d
  end
end
