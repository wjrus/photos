class MapsController < ApplicationController
  before_action :require_privileged_metadata_viewer!

  def show
    @google_maps_api_key = ENV["GOOGLE_MAPS_EMBED_API_KEY"]
    @albums = PhotoAlbum.visible_to(current_user).display_order
    @selected_album = @albums.find_by(id: params[:album_id]) if params[:album_id].present?
    @map_return_path = @selected_album ? map_path(album_id: @selected_album.id) : map_path
    @map_markers = geotagged_photos.map do |photo|
      metadata = photo.metadata
      {
        id: photo.id,
        title: photo.title,
        latitude: metadata.latitude.to_f,
        longitude: metadata.longitude.to_f,
        photo_url: photo_path(photo, return_to: @map_return_path),
        media_url: photo.image? ? display_photo_path(photo) : nil
      }
    end
  end

  private

  def geotagged_photos
    scope = if @selected_album
      @selected_album.photos
    else
      Photo
    end

    scope
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
