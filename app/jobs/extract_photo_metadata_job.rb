require "vips"

class ExtractPhotoMetadataJob < ApplicationJob
  queue_as :default

  def perform(photo)
    metadata = photo.metadata || photo.build_metadata

    unless photo.original.attached?
      metadata.update!(extraction_status: "failed", extraction_error: "Original is not attached", extracted_at: Time.current)
      return
    end

    unless photo.image?
      metadata.update!(extraction_status: "unsupported", extraction_error: nil, raw: {}, extracted_at: Time.current)
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
        raw: exif,
        extracted_at: Time.current
      )
      photo.update_columns(captured_at: captured_at, updated_at: Time.current) if captured_at
    end
  rescue StandardError => e
    (photo.metadata || photo.build_metadata).update!(
      extraction_status: "failed",
      extraction_error: e.message,
      extracted_at: Time.current
    )
    raise
  end

  private

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
