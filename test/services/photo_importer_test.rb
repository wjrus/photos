require "test_helper"

class PhotoImporterTest < ActiveSupport::TestCase
  test "imports media files and pairs edited apple sidecars" do
    owner = users(:one)

    assert_difference "Photo.count", 1 do
      PhotoImporter.new(owner: owner).import([
        uploaded_file("fake heic bytes", "IMG_E0073.HEIC", "image/heic"),
        uploaded_file("<?xml version=\"1.0\"?>", "IMG_O0073.AAE", "application/xml")
      ])
    end

    photo = Photo.find_by!(original_filename: "IMG_E0073.HEIC")
    assert_equal owner, photo.owner
    assert_equal 1, photo.sidecar_count
  end

  test "attaches imported photos to an upload batch" do
    owner = users(:one)
    upload_batch = UploadBatch.create!(owner: owner)

    PhotoImporter.new(owner: owner, upload_batch: upload_batch).import([
      uploaded_file("fake jpg bytes", "IMG_1000.JPG", "image/jpeg")
    ])

    photo = Photo.find_by!(original_filename: "IMG_1000.JPG")
    assert_equal upload_batch, photo.upload_batch
  end

  private

  def uploaded_file(body, filename, content_type)
    Rack::Test::UploadedFile.new(StringIO.new(body), content_type, original_filename: filename)
  end
end
