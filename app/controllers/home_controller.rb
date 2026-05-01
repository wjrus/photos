class HomeController < ApplicationController
  def show
    @photos = Photo.with_attached_original.visible_to(current_user).stream_order
    @photo = Photo.new
  end
end
