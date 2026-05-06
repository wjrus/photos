class PhotosController < ApplicationController
  owner_access_message "Only the owner can manage photos."

  before_action :require_owner!, except: %i[show display video]
  before_action :set_visible_photo, only: %i[show display video]
  before_action :set_photo, only: %i[media caption publish unpublish retry_archive destroy]

  def show
    if params[:return_to].present?
      store_photo_return_path(safe_return_path)
      redirect_to photo_path(@photo), status: :see_other
      return
    end

    @return_to = photo_return_path(@photo)
    @taggable_users = User.where.not(id: current_user.id).order(Arel.sql("LOWER(email) ASC")) if current_user&.owner?
    @cover_context = photo_cover_context(@photo, @return_to) if current_user&.owner?
    set_stream_neighbors
  end

  def display
    return head :not_found if @photo.video?

    variant = @photo.original.variant(:display).processed
    send_data variant.download,
      type: "image/jpeg",
      disposition: "inline",
      filename: public_filename(@photo, ".jpg")
  end

  def video
    return head :not_found unless @photo.video? && @photo.video_display.attached?

    redirect_to rails_blob_path(@photo.video_display, disposition: "inline")
  end

  def media
    send_data @photo.original.download,
      type: @photo.content_type,
      disposition: "inline",
      filename: public_filename(@photo, File.extname(@photo.original_filename.to_s))
  end

  def caption
    @photo.update!(caption_params)
    store_photo_return_path(safe_return_path)
    redirect_to photo_path(@photo), notice: "Caption saved."
  end

  def create
    if batch_upload?
      result = create_batch_photos
      return if performed?

      redirect_to safe_return_path, notice: "Uploaded #{result[:created]} private item#{'s' unless result[:created] == 1}."
      return
    end

    @photo = current_user.photos.new(photo_params.merge(upload_batch: active_upload_batch))

    if @photo.save
      redirect_to safe_return_path, notice: "Photo uploaded privately."
    else
      redirect_to safe_return_path, alert: @photo.errors.full_messages.to_sentence
    end
  end

  def publish
    @photo.publish!
    redirect_to visibility_return_path, notice: "Photo published."
  end

  def unpublish
    @photo.unpublish!
    redirect_to visibility_return_path, notice: "Photo returned to private."
  end

  def retry_archive
    @photo.drive_archive_object&.update!(status: "pending", error: nil)
    MirrorOriginalToDriveJob.perform_later(@photo)
    store_photo_return_path(safe_return_path)
    redirect_to photo_path(@photo), notice: "Drive archive retry queued."
  end

  def destroy
    @photo.destroy!
    redirect_to root_path, notice: "Photo removed."
  end

  def retry_failed_archives
    archive_objects = DriveArchiveObject
      .joins(:photo)
      .includes(:photo)
      .where(status: "failed", photos: { owner_id: current_user.id })
    retry_count = archive_objects.count

    archive_objects.find_each do |archive_object|
      archive_object.update!(status: "pending", error: nil)
      MirrorOriginalToDriveJob.perform_later(archive_object.photo)
    end

    redirect_to root_path, notice: "Queued #{retry_count} failed Drive archive #{'retry'.pluralize(retry_count)}."
  end

  private

  def photo_params
    params.require(:photo).permit(:title, :description, :original, sidecars: [])
  end

  def caption_params
    params.require(:photo).permit(:description)
  end

  def visibility_return_path
    safe_return_path
  end

  def batch_upload?
    params.dig(:photos, :files).present?
  end

  def create_batch_photos
    files = Array(params.require(:photos).permit(files: [])[:files]).compact_blank
    PhotoImporter.new(owner: current_user, upload_batch: active_upload_batch).import(files)
  rescue ActiveRecord::RecordInvalid => e
    redirect_to root_path, alert: e.record.errors.full_messages.to_sentence
    {}
  end

  def set_photo
    @photo = manageable_photo_scope.find(params[:id])
  end

  def set_visible_photo
    @photo = visible_photo_scope.find(params[:id])
  end

  def set_stream_neighbors
    stream = navigation_stream
    @previous_photo = stream.stream_before(@photo)
    @next_photo = stream.stream_after(@photo)
  end

  def navigation_stream
    return current_user.photos.restricted.stream_order if restricted_return_path?
    return current_user.photos.archived.stream_order if archived_return_path?

    album = return_to_album
    return album.photos.visible_to(current_user).stream_order if album

    Photo.visible_to(current_user).stream_order
  end

  def visible_photo_scope
    return current_user.photos.with_attached_original if current_user&.owner? && restricted_photos_unlocked?
    return current_user.photos.archived.with_attached_original if archived_return_path?

    Photo.with_attached_original.visible_to(current_user)
  end

  def manageable_photo_scope
    scope = current_user.photos
    return scope if restricted_photos_unlocked?
    return scope.archived if archived_return_path?

    scope.visible_to(current_user)
  end

  def restricted_return_path?
    current_user&.owner? && restricted_photos_unlocked? && safe_return_path == restricted_photos_path
  end

  def archived_return_path?
    current_user&.owner? && safe_return_path == archived_photos_path
  end

  def return_to_album
    match = safe_return_path.match(%r{\A/albums/(\d+)\z})
    return unless match

    PhotoAlbum.visible_to(current_user).find_by(id: match[1])
  end

  def public_filename(photo, extension)
    return photo.original_filename if current_user&.owner?

    "photo-#{photo.id}#{extension}"
  end

  def active_upload_batch
    UploadBatch.active_for(current_user)
  end

  def photo_return_path(photo)
    return_path = safe_return_path(default: root_path(photo_id: photo.id))
    uri = URI.parse(return_path)

    return root_path(photo_id: photo.id) if uri.relative? && [ "", root_path ].include?(uri.path)

    return_path
  rescue URI::InvalidURIError
    root_path(photo_id: photo.id)
  end

  def photo_cover_context(photo, return_path)
    album_cover_context(photo, return_path) || location_cover_context(photo, return_path)
  end

  def album_cover_context(photo, return_path)
    album_id = return_path.to_s.match(%r{\A/albums/(\d+)\z})&.[](1)
    return unless album_id

    album = current_user.photo_albums.find_by(id: album_id)
    return unless album&.photos&.exists?(photo.id)

    {
      label: "Set album cover",
      path: album_cover_path(album, photo)
    }
  end

  def location_cover_context(photo, return_path)
    location_id = return_path.to_s.match(%r{\A/locations/([^/?#]+)\z})&.[](1)
    return unless location_id && PhotoLocation.valid_id?(location_id)

    return unless PhotoLocation.scope_for(geotagged_photo_scope, location_id).exists?(photo.id)

    {
      label: "Set location cover",
      path: location_cover_path(location_id, photo)
    }
  end

  def geotagged_photo_scope
    current_user.photos
      .visible_to(current_user)
      .joins(:metadata)
      .where.not(photo_metadata: { latitude: nil, longitude: nil })
  end
end
