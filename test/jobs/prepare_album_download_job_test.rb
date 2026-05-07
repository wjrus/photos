require "test_helper"
require "zip"

class PrepareAlbumDownloadJobTest < ActiveJob::TestCase
  test "prepares a zip and updates progress" do
    owner = users(:one)
    album = owner.photo_albums.create!(title: "Job Trip", source: "manual")
    visible = attached_photo(owner, title: "Visible")
    archived = attached_photo(owner, title: "Archived")
    archived.archive!
    album.photos << visible
    album.photos << archived
    download = owner.album_downloads.create!(photo_album: album, filename: "job-trip-album.zip")

    PrepareAlbumDownloadJob.perform_now(download)

    download.reload
    assert_predicate download, :ready?
    assert_equal 1, download.total_entries
    assert_equal 1, download.processed_entries
    assert_nil download.zip_path
    assert_predicate download.archive, :attached?

    download.archive.open do |file|
      Zip::File.open(file.path) do |zip|
        assert_equal [ "0001-visible.png" ], zip.map(&:name)
      end
    end
  ensure
    download&.archive&.purge
  end

  private

  def attached_photo(owner, title:)
    photo = owner.photos.new(title: title)
    photo.original.attach(
      io: File.open(Rails.root.join("public/icon.png")),
      filename: "#{title.parameterize}.png",
      content_type: "image/png"
    )
    photo.save!
    photo
  end
end
