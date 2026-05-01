class PhotosController < ApplicationController
  before_action :require_owner!, except: %i[show display media]
  before_action :set_visible_photo, only: %i[show display media]
  before_action :set_photo, only: %i[publish unpublish]

  def show
  end

  def display
    return media if @photo.video?

    variant = @photo.original.variant(:display).processed
    send_data variant.download,
      type: @photo.content_type,
      disposition: "inline",
      filename: public_filename(@photo, ".jpg")
  end

  def media
    send_data @photo.original.download,
      type: @photo.content_type,
      disposition: "inline",
      filename: public_filename(@photo, File.extname(@photo.original_filename.to_s))
  end

  def create
    @photo = current_user.photos.new(photo_params)

    if @photo.save
      redirect_to root_path, notice: "Photo uploaded privately."
    else
      redirect_to root_path, alert: @photo.errors.full_messages.to_sentence
    end
  end

  def publish
    @photo.publish!
    redirect_to root_path, notice: "Photo published."
  end

  def unpublish
    @photo.unpublish!
    redirect_to root_path, notice: "Photo returned to private."
  end

  private

  def photo_params
    params.require(:photo).permit(:title, :description, :original)
  end

  def set_photo
    @photo = current_user.photos.find(params[:id])
  end

  def set_visible_photo
    @photo = Photo.with_attached_original.visible_to(current_user).find(params[:id])
  end

  def require_owner!
    return if current_user&.owner?

    redirect_to root_path, alert: "Only the owner can manage photos."
  end

  def public_filename(photo, extension)
    return photo.original_filename if current_user&.owner?

    "photo-#{photo.id}#{extension}"
  end
end
