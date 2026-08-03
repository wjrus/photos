class AlbumAccessLinksController < ApplicationController
  EXPIRATION_OPTIONS = {
    "never" => nil,
    "7_days" => 7.days,
    "30_days" => 30.days,
    "90_days" => 90.days,
    "1_year" => 1.year
  }.freeze

  owner_access_message "Only the owner can manage album links."
  before_action :require_owner!

  def create
    album = current_user.photo_albums.find(params[:album_id])
    expiration = EXPIRATION_OPTIONS.fetch(params[:expires_in].presence || "never")
    album.album_access_links.create!(
      created_by: current_user,
      label: params[:label].presence || "Share link",
      expires_at: expiration&.from_now
    )

    redirect_to album_path(album), notice: "Share link created."
  rescue KeyError
    redirect_to album_path(params[:album_id]), alert: "Choose a valid expiration."
  rescue ActiveRecord::RecordInvalid => error
    redirect_to album_path(params[:album_id]), alert: error.record.errors.full_messages.to_sentence
  end

  def revoke
    link = AlbumAccessLink.joins(:photo_album)
      .where(photo_albums: { owner_id: current_user.id })
      .find(params[:id])
    link.revoke!

    redirect_to album_path(link.photo_album), notice: "Share link revoked."
  end
end
