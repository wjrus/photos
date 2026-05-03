class PhotosController < ApplicationController
  before_action :require_owner!, except: %i[show display]
  before_action :set_visible_photo, only: %i[show display]
  before_action :set_photo, only: %i[media caption publish unpublish retry_archive destroy]

  def show
    @return_to = safe_return_path
    @taggable_users = User.where.not(id: current_user.id).order(Arel.sql("LOWER(email) ASC")) if current_user&.owner?
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

  def media
    send_data @photo.original.download,
      type: @photo.content_type,
      disposition: "inline",
      filename: public_filename(@photo, File.extname(@photo.original_filename.to_s))
  end

  def caption
    @photo.update!(caption_params)
    redirect_to photo_path(@photo, return_to: safe_return_path), notice: "Caption saved."
  end

  def create
    if batch_upload?
      result = create_batch_photos
      return if performed?

      redirect_to safe_return_path, notice: "Uploaded #{result[:created]} private item#{'s' unless result[:created] == 1}."
      return
    end

    @photo = current_user.photos.new(photo_params)

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
    redirect_to photo_path(@photo, return_to: safe_return_path), notice: "Drive archive retry queued."
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

  def safe_return_path
    return root_path if params[:return_to].blank?

    uri = URI.parse(params[:return_to])
    return params[:return_to] if uri.relative?

    root_path
  rescue URI::InvalidURIError
    root_path
  end

  def batch_upload?
    params.dig(:photos, :files).present?
  end

  def create_batch_photos
    files = Array(params.require(:photos).permit(files: [])[:files]).compact_blank
    PhotoImporter.new(owner: current_user).import(files)
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
    stream_ids = stream.pluck(:id)
    current_index = stream_ids.index(@photo.id)
    return unless current_index

    @previous_photo = stream.find_by(id: stream_ids[current_index - 1]) if current_index.positive?
    @next_photo = stream.find_by(id: stream_ids[current_index + 1]) if stream_ids[current_index + 1]
  end

  def navigation_stream
    return current_user.photos.restricted.stream_order if restricted_return_path?

    album = return_to_album
    return album.photos.visible_to(current_user).stream_order if album

    Photo.visible_to(current_user).stream_order
  end

  def visible_photo_scope
    return current_user.photos.with_attached_original if current_user&.owner? && restricted_photos_unlocked?

    Photo.with_attached_original.visible_to(current_user)
  end

  def manageable_photo_scope
    scope = current_user.photos
    restricted_photos_unlocked? ? scope : scope.visible_to(current_user)
  end

  def restricted_return_path?
    current_user&.owner? && restricted_photos_unlocked? && safe_return_path == restricted_photos_path
  end

  def return_to_album
    match = safe_return_path.match(%r{\A/albums/(\d+)\z})
    return unless match

    PhotoAlbum.visible_to(current_user).find_by(id: match[1])
  end

  def require_owner!
    return if current_user&.owner?

    redirect_to root_path, alert: "Only the owner can manage photos."
  end

  def public_filename(photo, extension)
    return photo.original_filename if current_user&.owner?

    "photo-#{photo.id}#{extension}"
  end
end
