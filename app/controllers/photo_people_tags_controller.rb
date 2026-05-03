class PhotoPeopleTagsController < ApplicationController
  before_action :require_owner!

  def create
    photo = current_user.photos.find(params[:photo_id])
    user = User.where.not(id: current_user.id).find(params[:user_id])
    photo.photo_people_tags.find_or_create_by!(user: user) do |tag|
      tag.tagged_by = current_user
    end
    redirect_to photo_path(photo, return_to: safe_return_path), notice: "#{user.display_name} tagged."
  end

  def destroy
    tag = PhotoPeopleTag.joins(:photo).where(photos: { owner_id: current_user.id }).find(params[:id])
    photo = tag.photo
    tag.destroy!
    redirect_to photo_path(photo, return_to: safe_return_path), notice: "Tag removed."
  end

  private

  def safe_return_path
    return root_path if params[:return_to].blank?

    uri = URI.parse(params[:return_to])
    return params[:return_to] if uri.relative?

    root_path
  rescue URI::InvalidURIError
    root_path
  end

  def require_owner!
    return if current_user&.owner?

    redirect_to root_path, alert: "Only the owner can tag people."
  end
end
