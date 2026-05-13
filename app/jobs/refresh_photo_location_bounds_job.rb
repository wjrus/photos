class RefreshPhotoLocationBoundsJob < ApplicationJob
  queue_as :maintenance

  def perform
    PhotoLocationBound.refresh_all!
  end
end
