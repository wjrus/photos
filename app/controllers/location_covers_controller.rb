class LocationCoversController < ApplicationController
  owner_access_message "Only the owner can manage location covers."

  before_action :require_owner!
  before_action :set_location

  def update
    photo = location_photo_scope.find(params[:photo_id])
    cover = current_user.photo_location_covers.find_or_initialize_by(location_id: @location_id)
    cover.cover_photo = photo
    cover.save!

    redirect_to location_path(@location_id), notice: "Location cover updated."
  end

  private

  def set_location
    @location_id = params[:location_id].to_s
    raise ActiveRecord::RecordNotFound unless PhotoLocation.valid_id?(@location_id)
  end

  def location_photo_scope
    PhotoLocation.scope_for(geotagged_photos, @location_id)
  end

  def geotagged_photos
    current_user.photos
      .visible_to(current_user)
      .joins(:metadata)
      .where.not(photo_metadata: { latitude: nil, longitude: nil })
  end
end
