require "test_helper"

class PhotoDirectoryImporterTest < ActiveSupport::TestCase
  setup do
    @owner = users(:one)
    @directory = Pathname(Dir.mktmpdir("photo-directory-import"))
  end

  teardown do
    FileUtils.remove_entry(@directory) if @directory.exist?
  end

  test "recursively imports media, pairs sidecars, commits a batch, and queues normal processing" do
    nested = @directory.join("phone")
    nested.mkpath
    FileUtils.cp(Rails.root.join("public/icon.png"), nested.join("IMG_E0073.PNG"))
    nested.join("IMG_O0073.AAE").write("<xml />")
    @directory.join("notes.txt").write("not a photo")

    summary = nil
    assert_enqueued_with(job: ExtractPhotoMetadataJob) do
      assert_enqueued_with(job: GeneratePhotoDerivativesJob) do
        assert_enqueued_with(job: MirrorOriginalToDriveJob) do
          summary = PhotoDirectoryImporter.new(owner: @owner).import_path(@directory)
        end
      end
    end

    photo = @owner.photos.find_by!(original_filename: "IMG_E0073.PNG")
    assert_equal "complete", photo.checksum_status
    assert_match(/\A[0-9a-f]{64}\z/, photo.checksum_sha256)
    assert_equal 1, photo.sidecar_count
    assert_equal "committed", photo.upload_batch.status
    assert_equal 1, summary.fetch(:imported)
    assert_equal 1, summary.fetch(:sidecars)
    assert_equal 1, summary.fetch(:ignored)
    assert_equal photo.upload_batch_id, summary.fetch(:upload_batch_id)
  end

  test "reruns skip originals already imported by checksum" do
    FileUtils.cp(Rails.root.join("public/icon.png"), @directory.join("first.png"))
    importer = PhotoDirectoryImporter.new(owner: @owner)

    first = importer.import_path(@directory)
    second = PhotoDirectoryImporter.new(owner: @owner).import_path(@directory)

    assert_equal 1, first.fetch(:imported)
    assert_equal 0, second.fetch(:imported)
    assert_equal 1, second.fetch(:duplicates)
    assert_nil second.fetch(:upload_batch_id)
    assert_equal 1, @owner.photos.where(original_filename: "first.png").count
  end

  test "dry run reports imports without creating photos or batches" do
    FileUtils.cp(Rails.root.join("public/icon.png"), @directory.join("preview.png"))

    assert_no_difference [ "Photo.count", "UploadBatch.count" ] do
      summary = PhotoDirectoryImporter.new(owner: @owner, dry_run: true).import_path(@directory)

      assert_equal 1, summary.fetch(:would_import)
      assert_equal 0, summary.fetch(:imported)
    end
  end

  test "does not pair sidecars across different directories" do
    first = @directory.join("first")
    second = @directory.join("second")
    first.mkpath
    second.mkpath
    FileUtils.cp(Rails.root.join("public/icon.png"), first.join("same.png"))
    second.join("same.AAE").write("<xml />")

    summary = PhotoDirectoryImporter.new(owner: @owner).import_path(@directory)

    assert_equal 0, @owner.photos.find_by!(original_filename: "same.png").sidecar_count
    assert_equal 1, summary.fetch(:orphan_sidecars)
  end
end
