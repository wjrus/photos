module LocationsHelper
  def location_cover_preload_tags
    safe_join(priority_location_covers.map.with_index do |photo, index|
      tag.link(rel: "preload", as: "image", href: stream_photo_path(photo), fetchpriority: index.zero? ? "high" : "auto")
    end)
  end

  def location_cover_image_options(photo)
    return {} unless priority_location_covers.include?(photo)

    { loading: "eager", fetchpriority: priority_location_covers.first == photo ? "high" : "auto" }
  end

  private

  def priority_location_covers
    return [] if @location_page.to_i > 1

    @priority_location_covers ||= Array(@locations).first(3).filter_map { |location| @location_covers[location.id] }.select do |photo|
      attachment = photo.video? ? photo.video_preview : photo.processed_original_variant_record(:stream)&.image
      attached_blob_available?(attachment)
    end
  end
end
