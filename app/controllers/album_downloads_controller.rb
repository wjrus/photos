class AlbumDownloadsController < ApplicationController
  owner_access_message "Only the owner can download album archives."

  before_action :require_owner!
  before_action :set_album_download, only: %i[show file]

  def create
    album = current_user.photo_albums.find(params[:album_id])
    download = current_user.album_downloads.create!(
      photo_album: album,
      filename: "#{album.title.to_s.parameterize.presence || "album-#{album.id}"}-album.zip"
    )
    PrepareAlbumDownloadJob.perform_later(download)

    render json: download_payload(download), status: :accepted
  end

  def show
    render json: download_payload(@album_download)
  end

  def file
    zip_file_path = AlbumDownload.zip_file_path_for(@album_download.id)

    unless @album_download.ready? && zip_file_path.file?
      redirect_to album_path(@album_download.photo_album), alert: "Album ZIP is not ready yet."
      return
    end

    send_file zip_file_path.to_s,
      type: "application/zip",
      disposition: "attachment",
      filename: @album_download.filename
  end

  private

  def set_album_download
    @album_download = current_user.album_downloads.find(params[:id])
  end

  def download_payload(download)
    {
      id: download.id,
      status: download.status,
      total_entries: download.total_entries,
      processed_entries: download.processed_entries,
      progress_percent: download.progress_percent,
      error: download.error,
      show_url: album_download_path(download),
      file_url: (file_album_download_path(download) if download.ready?)
    }
  end
end
