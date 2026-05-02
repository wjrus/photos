class MapsController < ApplicationController
  before_action :require_privileged_metadata_viewer!

  def show
    @google_maps_api_key = ENV["GOOGLE_MAPS_EMBED_API_KEY"]
    @map_markers = geotagged_photos.map do |photo|
      metadata = photo.metadata
      {
        id: photo.id,
        title: photo.title,
        latitude: metadata.latitude.to_f,
        longitude: metadata.longitude.to_f,
        photo_url: photo_path(photo),
        media_url: photo.image? ? display_photo_path(photo) : nil
      }
    end
  end

  private

  def geotagged_photos
    Photo
      .with_attached_original
      .visible_to(current_user)
      .joins(:metadata)
      .where.not(photo_metadata: { latitude: nil, longitude: nil })
      .stream_order
  end

  def require_privileged_metadata_viewer!
    return if privileged_metadata_viewer?

    redirect_to root_path, alert: "Only trusted viewers can see the photo map."
  end
end
