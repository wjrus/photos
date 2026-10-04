class CleanupMobileUploadsJob < ApplicationJob
  queue_as :maintenance

  def perform
    MobileUpload.where("expires_at < ?", Time.current).find_each do |upload|
      upload.with_lock { upload.destroy! if upload.expires_at.past? }
    end
  end
end
