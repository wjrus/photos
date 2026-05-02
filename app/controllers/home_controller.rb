class HomeController < ApplicationController
  def show
    @photos = Photo.with_attached_original.visible_to(current_user).stream_order
    @photo = Photo.new
    @failed_drive_archive_count = failed_drive_archive_count
  end

  private

  def failed_drive_archive_count
    return 0 unless current_user&.owner?

    current_user.photos.joins(:drive_archive_object).where(drive_archive_objects: { status: "failed" }).count
  end
end
