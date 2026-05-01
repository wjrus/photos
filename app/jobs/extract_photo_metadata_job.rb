require "exifr/jpeg"

class ExtractPhotoMetadataJob < ApplicationJob
  queue_as :default

  def perform(photo)
    metadata = photo.metadata || photo.build_metadata

    unless photo.original.attached?
      metadata.update!(extraction_status: "failed", extraction_error: "Original is not attached", extracted_at: Time.current)
      return
    end

    unless jpeg?(photo)
      metadata.update!(extraction_status: "unsupported", extraction_error: nil, raw: {}, extracted_at: Time.current)
      return
    end

    photo.original.blob.open do |file|
      exif = EXIFR::JPEG.new(file.path)
      gps = exif.gps

      metadata.update!(
        extraction_status: "complete",
        extraction_error: nil,
        captured_at: exif.date_time_original || exif.date_time,
        camera_make: exif.make,
        camera_model: exif.model,
        lens_model: exif.lens_model,
        iso: Array(exif.iso_speed_ratings).first,
        aperture: exif.f_number&.to_s,
        exposure_time: exif.exposure_time&.to_s,
        focal_length: exif.focal_length&.to_s,
        latitude: gps&.latitude,
        longitude: gps&.longitude,
        raw: exif.exif? ? exif.to_hash.compact.transform_values(&:to_s) : {},
        extracted_at: Time.current
      )
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

  def jpeg?(photo)
    photo.content_type.to_s.in?(%w[image/jpeg image/jpg])
  end
end
