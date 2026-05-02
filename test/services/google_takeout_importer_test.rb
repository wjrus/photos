require "test_helper"
require "zip"

class GoogleTakeoutImporterTest < ActiveSupport::TestCase
  setup do
    @owner = users(:one)
    @zip_path = Rails.root.join("tmp/google_takeout_importer_test-#{Process.pid}-#{SecureRandom.hex(8)}.zip")
    FileUtils.rm_f(@zip_path)
  end

  teardown do
    FileUtils.rm_f(@zip_path)
  end

  test "imports media from takeout zip with json metadata and skips report files" do
    write_zip(
      "Takeout/Google Photos/Photos from 2024/IMG_0001.JPG" => "fake jpeg bytes",
      "Takeout/Google Photos/Photos from 2024/IMG_0001.JPG.supplemental-metadata.json" => google_json(
        title: "IMG_0001.JPG",
        description: "Lake day.",
        timestamp: "1714586400",
        latitude: 44.762222,
        longitude: -85.597983
      ),
      "Takeout/Google Photos/Photos from 2024/metadata.json" => { title: "Photos from 2024" }.to_json,
      "Takeout/archive_browser.html" => "<html>report</html>"
    )

    assert_difference "Photo.count", 1 do
      summary = GoogleTakeoutImporter.new(owner: @owner).import_path(@zip_path)
      assert_equal 1, summary.fetch(:imported)
      assert_equal 2, summary.fetch(:sidecars)
      assert_equal 1, summary.fetch(:skipped)
      assert_equal 1, summary.fetch(:albums)
      assert_equal 1, summary.fetch(:album_memberships)
    end

    photo = Photo.find_by!(original_filename: "IMG_0001.JPG")
    assert_equal "Lake day.", photo.description
    assert_equal "complete", photo.checksum_status
    assert_equal Digest::SHA256.hexdigest("fake jpeg bytes"), photo.checksum_sha256
    assert_equal Time.zone.at(1_714_586_400), photo.captured_at
    assert_in_delta 44.762222, photo.metadata.latitude.to_f, 0.000001
    assert_in_delta(-85.597983, photo.metadata.longitude.to_f, 0.000001)
    assert_equal [ "Photos from 2024" ], photo.photo_albums.pluck(:title)
    assert_equal "imported", GoogleTakeoutImport.find_by!(entry_name: "Takeout/Google Photos/Photos from 2024/IMG_0001.JPG").status
  end

  test "skips duplicate media by sha256" do
    existing = attached_photo(checksum_sha256: Digest::SHA256.hexdigest("duplicate bytes"))
    write_zip("Takeout/Google Photos/duplicate.JPG" => "duplicate bytes")

    assert_no_difference "Photo.count" do
      summary = GoogleTakeoutImporter.new(owner: @owner).import_path(@zip_path)
      assert_equal 1, summary.fetch(:duplicates)
    end

    import_record = GoogleTakeoutImport.find_by!(entry_name: "Takeout/Google Photos/duplicate.JPG")
    assert_equal "duplicate", import_record.status
    assert_equal existing, import_record.photo
  end

  test "resumes already imported entries" do
    write_zip("Takeout/Google Photos/IMG_0002.PNG" => File.binread(Rails.root.join("public/icon.png")))
    importer = GoogleTakeoutImporter.new(owner: @owner)

    first_summary = importer.import_path(@zip_path)
    assert_equal 1, first_summary.fetch(:imported)

    assert_no_difference "Photo.count" do
      summary = importer.import_path(@zip_path)
      assert_equal 1, summary.fetch(:already_imported)
    end
  end

  test "preserves takeout folders as albums including date named folders" do
    write_zip(
      "Takeout/Google Photos/2010-09-03/DSC_4313.JPG" => "old import",
      "Takeout/Google Photos/2010-09-03/DSC_4313.JPG.supplemental-metadata.json" => google_json(
        title: "DSC_4313.JPG",
        description: "Old album date.",
        timestamp: "1283544000",
        latitude: 0,
        longitude: 0
      ),
      "Takeout/Google Photos/2010-09-03/metadata.json" => { title: "2010-09-03" }.to_json,
      "Takeout/Google Photos/Good Lorde/IMG_5401.HEIC" => "concert",
      "Takeout/Google Photos/Good Lorde/IMG_5401.HEIC.supplemental-metadata.json" => google_json(
        title: "IMG_5401.HEIC",
        description: "Lorde.",
        timestamp: "1751241600",
        latitude: 44.0,
        longitude: -85.0
      ),
      "Takeout/Google Photos/Good Lorde/metadata.json" => { title: "Good Lorde" }.to_json
    )

    summary = GoogleTakeoutImporter.new(owner: @owner).import_path(@zip_path)

    assert_equal 2, summary.fetch(:imported)
    assert_equal 2, summary.fetch(:albums)
    assert_equal 2, summary.fetch(:album_memberships)
    assert_equal [ "2010-09-03" ], Photo.find_by!(original_filename: "DSC_4313.JPG").photo_albums.pluck(:title)
    assert_equal [ "Good Lorde" ], Photo.find_by!(original_filename: "IMG_5401.HEIC").photo_albums.pluck(:title)
  end

  test "adds duplicate media to takeout albums without creating another photo" do
    existing = attached_photo(checksum_sha256: Digest::SHA256.hexdigest("same bytes"))
    write_zip(
      "Takeout/Google Photos/Trip to Cleveland/IMG_8287.HEIC" => "same bytes",
      "Takeout/Google Photos/Trip to Cleveland/metadata.json" => { title: "Trip to Cleveland" }.to_json
    )

    assert_no_difference "Photo.count" do
      summary = GoogleTakeoutImporter.new(owner: @owner).import_path(@zip_path)
      assert_equal 1, summary.fetch(:duplicates)
      assert_equal 1, summary.fetch(:album_memberships)
    end

    assert_equal [ "Trip to Cleveland" ], existing.photo_albums.pluck(:title)
  end

  private

  def write_zip(entries)
    Zip::File.open(@zip_path.to_s, create: true) do |zip|
      entries.each do |name, body|
        zip.get_output_stream(name) { |stream| stream.write(body) }
      end
    end
  end

  def google_json(title:, description:, timestamp:, latitude:, longitude:)
    {
      title: title,
      description: description,
      photoTakenTime: { timestamp: timestamp },
      geoData: { latitude: latitude, longitude: longitude },
      geoDataExif: { latitude: latitude, longitude: longitude }
    }.to_json
  end

  def attached_photo(checksum_sha256:)
    photo = @owner.photos.new(checksum_sha256: checksum_sha256, checksum_status: "complete")
    photo.original.attach(
      io: StringIO.new("existing"),
      filename: "existing.jpg",
      content_type: "image/jpeg"
    )
    photo.save!
    photo
  end
end
