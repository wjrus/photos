class PhotosController < ApplicationController
  before_action :require_owner!, except: %i[show display]
  before_action :set_visible_photo, only: %i[show display]
  before_action :set_photo, only: %i[media caption publish unpublish retry_archive]

  def show
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
    redirect_to photo_path(@photo), notice: "Caption saved."
  end

  def create
    if batch_upload?
      result = create_batch_photos
      return if performed?

      redirect_to root_path, notice: "Uploaded #{result[:created]} private item#{'s' unless result[:created] == 1}."
      return
    end

    @photo = current_user.photos.new(photo_params)

    if @photo.save
      redirect_to root_path, notice: "Photo uploaded privately."
    else
      redirect_to root_path, alert: @photo.errors.full_messages.to_sentence
    end
  end

  def publish
    @photo.publish!
    redirect_to root_path, notice: "Photo published."
  end

  def unpublish
    @photo.unpublish!
    redirect_to root_path, notice: "Photo returned to private."
  end

  def retry_archive
    @photo.drive_archive_object&.update!(status: "pending", error: nil)
    MirrorOriginalToDriveJob.perform_later(@photo)
    redirect_to photo_path(@photo), notice: "Drive archive retry queued."
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

  def batch_upload?
    params.dig(:photos, :files).present?
  end

  def create_batch_photos
    files = Array(params.require(:photos).permit(files: [])[:files]).compact_blank
    sidecars, originals = files.partition { |file| sidecar_file?(file) }
    sidecars_by_basename = sidecars.group_by { |file| import_basename(file) }
    created = 0

    Photo.transaction do
      originals.each do |original|
        photo = current_user.photos.new
        photo.original.attach(original)
        Array(sidecars_by_basename[import_basename(original)]).each { |sidecar| photo.sidecars.attach(sidecar) }
        photo.save!
        created += 1
      end
    end

    { created: created }
  rescue ActiveRecord::RecordInvalid => e
    redirect_to root_path, alert: e.record.errors.full_messages.to_sentence
    {}
  end

  def sidecar_file?(file)
    File.extname(file.original_filename.to_s).casecmp?(".aae")
  end

  def import_basename(file)
    basename = File.basename(file.original_filename.to_s, ".*").downcase
    basename.sub(/\A(img)_o(\d+)\z/, "\\1_e\\2")
  end

  def set_photo
    @photo = current_user.photos.find(params[:id])
  end

  def set_visible_photo
    @photo = Photo.with_attached_original.visible_to(current_user).find(params[:id])
  end

  def set_stream_neighbors
    stream = Photo.visible_to(current_user).stream_order
    stream_ids = stream.pluck(:id)
    current_index = stream_ids.index(@photo.id)
    return unless current_index

    @previous_photo = stream.find_by(id: stream_ids[current_index - 1]) if current_index.positive?
    @next_photo = stream.find_by(id: stream_ids[current_index + 1]) if stream_ids[current_index + 1]
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
