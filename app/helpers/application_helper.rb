module ApplicationHelper
  def photo_display_image_path(photo)
    variant = photo.original.variant(:display)
    filename = current_user&.owner? ? photo.original.filename : "photo-#{photo.id}.jpg"

    rails_blob_representation_path(photo.original.blob.signed_id, variant.variation.key, filename)
  end
end
