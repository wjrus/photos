require "test_helper"

class ChecksumOriginalJobTest < ActiveJob::TestCase
  test "computes sha256 checksum for original" do
    photo = attached_photo

    ChecksumOriginalJob.perform_now(photo)

    assert_equal "complete", photo.reload.checksum_status
    assert_equal Digest::SHA256.file(Rails.root.join("public/icon.png")).hexdigest, photo.checksum_sha256
    assert_nil photo.checksum_error
    assert_predicate photo.checksum_checked_at, :present?
  end

  private

  def attached_photo
    photo = users(:one).photos.new
    photo.original.attach(
      io: File.open(Rails.root.join("public/icon.png")),
      filename: "fixture.png",
      content_type: "image/png"
    )
    photo.save!
    photo
  end
end
