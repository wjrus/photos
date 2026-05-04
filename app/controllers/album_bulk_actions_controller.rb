class AlbumBulkActionsController < ApplicationController
  owner_access_message "Only the owner can manage albums."

  before_action :require_owner!

  def create
    albums = current_user.photo_albums.where(id: selected_album_ids)
    return redirect_to albums_path, alert: "Select at least one album." if albums.empty?

    case params[:bulk_action]
    when "publish"
      albums.find_each(&:publish!)
      redirect_to albums_path, notice: "Published #{albums.size} #{'album'.pluralize(albums.size)}."
    when "unpublish"
      albums.find_each(&:unpublish!)
      redirect_to albums_path, notice: "Made #{albums.size} #{'album'.pluralize(albums.size)} private."
    when "delete"
      count = albums.size
      albums.destroy_all
      redirect_to albums_path, notice: "Removed #{count} #{'album'.pluralize(count)}."
    else
      redirect_to albums_path, alert: "Choose an action."
    end
  end

  private

  def selected_album_ids
    Array(params[:album_ids]).compact_blank
  end
end
