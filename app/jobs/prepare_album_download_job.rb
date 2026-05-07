class PrepareAlbumDownloadJob < ApplicationJob
  queue_as :default

  def perform(album_download)
    zip_path = nil
    album_download.update!(status: "processing", error: nil)
    album_download.archive.purge if album_download.archive.attached?

    photos = album_download.photo_album.photos
      .visible_to(album_download.user)
      .with_attached_original
      .stream_order
      .to_a

    album_download.update!(total_entries: photos.count, processed_entries: 0)

    exporter = AlbumZipExporter.new(
      album: album_download.photo_album,
      photos: photos,
      progress: ->(processed_entries) { album_download.update!(processed_entries: processed_entries) }
    )

    zip_path = exporter.export
    attach_archive(album_download, zip_path, exporter.filename)

    album_download.update!(
      status: "ready",
      zip_path: nil,
      filename: exporter.filename,
      processed_entries: photos.count
    )
  rescue StandardError => error
    album_download.update!(status: "failed", error: error.message.truncate(500))
    raise
  ensure
    FileUtils.rm_f(zip_path) if zip_path
  end

  private

  def attach_archive(album_download, zip_path, filename)
    File.open(zip_path, "rb") do |file|
      album_download.archive.attach(
        io: file,
        filename: filename,
        content_type: "application/zip"
      )
    end
  end
end
