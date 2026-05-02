class HomeController < ApplicationController
  def show
    @photos = Photo.with_attached_original.visible_to(current_user).stream_order
    @albums = current_user.photo_albums.display_order if current_user&.owner?
  end
end
