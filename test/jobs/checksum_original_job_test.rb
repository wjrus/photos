require "test_helper"

class ChecksumOriginalJobTest < ActiveJob::TestCase
  test "computes sha256 checksum for original" do
    photo = attached_photo

    assert_enqueued_with(job: MirrorOriginalToDriveJob) do
      ChecksumOriginalJob.perform_now(photo)
    end

    assert_equal "complete", photo.reload.checksum_status
    assert_equal Digest::SHA256.file(original_path).hexdigest, photo.checksum_sha256
    assert_nil photo.checksum_error
    assert_predicate photo.checksum_checked_at, :present?
  end

  test "rejects changed bytes and can retry after restoration" do
    photo = attached_photo
    blob = photo.original.blob
    blob.service.upload(blob.key, StringIO.new("\0" * blob.byte_size))

    assert_no_enqueued_jobs only: MirrorOriginalToDriveJob do
      assert_raises(ActiveStorage::IntegrityError) { ChecksumOriginalJob.perform_now(photo) }
    end
    assert_equal "failed", photo.reload.checksum_status
    assert_nil photo.checksum_sha256

    original_path.open("rb") do |file|
      blob.service.upload(blob.key, file, checksum: blob.checksum)
    end
    assert_enqueued_with(job: MirrorOriginalToDriveJob) { ChecksumOriginalJob.perform_now(photo) }
    assert_equal "complete", photo.reload.checksum_status
    assert_equal Digest::SHA256.file(original_path).hexdigest, photo.checksum_sha256
    assert_nil photo.checksum_error
  end

  test "records missing original bytes as a failed checksum" do
    photo = attached_photo
    photo.original.blob.delete

    assert_no_enqueued_jobs only: MirrorOriginalToDriveJob do
      assert_raises(ActiveStorage::FileNotFoundError) { ChecksumOriginalJob.perform_now(photo) }
    end
    assert_equal "failed", photo.reload.checksum_status
    assert_nil photo.checksum_sha256
    assert_predicate photo.checksum_checked_at, :present?
  end

  test "computes sha256 for a composed blob without an md5 checksum" do
    bytes = original_path.binread
    sources = [ bytes.byteslice(0, 32), bytes.byteslice(32..) ].map do |part|
      ActiveStorage::Blob.create_and_upload!(io: StringIO.new(part), filename: "part.png", content_type: "image/png", identify: false)
    end
    blob = ActiveStorage::Blob.compose(sources, filename: "fixture.png")
    photo = users(:one).photos.create!(original: blob)
    assert_nil blob.checksum

    assert_enqueued_with(job: MirrorOriginalToDriveJob) { ChecksumOriginalJob.perform_now(photo) }
    assert_equal "complete", photo.reload.checksum_status
    assert_equal Digest::SHA256.hexdigest(bytes), photo.checksum_sha256
  end

  private

  def original_path
    Rails.root.join("public/icon.png")
  end

  def attached_photo
    photo = users(:one).photos.new
    original_path.open("rb") do |file|
      photo.original.attach(io: file, filename: "fixture.png", content_type: "image/png")
      photo.save!
    end
    photo
  end
end
