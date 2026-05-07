class PrepareAlbumDownloadJob < ApplicationJob
  queue_as :default

  def perform(album_download)
    album_download.update!(status: "processing", error: nil)

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
    album_download.update!(
      status: "ready",
      zip_path: zip_path.to_s,
      filename: exporter.filename,
      processed_entries: photos.count
    )
  rescue StandardError => error
    album_download.update!(status: "failed", error: error.message.truncate(500))
    raise
  end
end
