class PublicPhotoImagesController < ActionController::Base
  def show
    photo = Photo.publicly_visible.find(params[:photo_id])
    return head :not_found if photo.video?

    variant = photo.original.variant(:display).processed
    expires_in 1.hour, public: true
    send_data variant.download,
      type: "image/jpeg",
      disposition: "inline",
      filename: "photo-#{photo.id}.jpg"
  end
end
