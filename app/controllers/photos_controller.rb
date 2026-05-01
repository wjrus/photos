class PhotosController < ApplicationController
  before_action :require_owner!
  before_action :set_photo, only: %i[publish unpublish]

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

  def require_owner!
    return if current_user&.owner?

    redirect_to root_path, alert: "Only the owner can manage photos."
  end
end
