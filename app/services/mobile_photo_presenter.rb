class MobilePhotoPresenter
  METADATA_FIELDS = %w[extraction_status captured_at width height camera_make camera_model lens_model exposure_time aperture iso focal_length video_duration video_codec audio_codec video_container video_frame_rate video_bitrate location_source].freeze

  def initialize(photo:, user:, device:)
    @photo, @user, @device = photo, user, device
  end

  def as_json(detail: false)
    metadata = @photo.display_metadata
    payload = { id: @photo.id, title: @photo.title, media_type: @photo.video? ? "video" : "image",
      captured_at: @photo.captured_at, created_at: @photo.created_at, updated_at: @photo.updated_at,
      width: metadata&.width, height: metadata&.height, cursor: @photo.stream_cursor,
      visibility: @photo.visibility, archived: @photo.archived?, restricted: @photo.restricted?,
      media: media_paths, permissions: { manage: @user.owner? && @photo.owner_id == @user.id,
        metadata: @user.trusted_viewer?, original: @user.owner? && @photo.owner_id == @user.id } }
    if detail
      payload[:description] = @photo.description if @user.trusted_viewer?
      payload[:albums] = @photo.photo_albums.merge(PhotoAlbum.visible_to(@user)).display_order.map { |album| { id: album.id, title: album.title } }
    end
    payload
  end

  def info
    return nil unless @user.trusted_viewer?

    metadata = @photo.metadata
    { photo_id: @photo.id, filename: @photo.original_filename, byte_size: @photo.byte_size,
      content_type: @photo.content_type, description: @photo.description,
      metadata: metadata&.attributes&.slice(*METADATA_FIELDS),
      location: (if metadata&.location?
        { latitude: metadata.latitude.to_f, longitude: metadata.longitude.to_f,
          name: metadata.photo_place&.name, location_id: PhotoLocation.id_for_metadata(metadata) }
                 end),
      people: @photo.photo_people_tags.includes(:user).map { |tag| { id: tag.id, user_id: tag.user_id, name: tag.user.display_name } },
      processing: { checksum: @photo.checksum_status, metadata: metadata&.extraction_status || "pending",
        video_ready: @photo.video_derivatives_ready? } }
  end

  private

  def media_paths
    base = "/api/v1/photos/#{@photo.id}/media"
    paths = if @photo.video?
      { thumbnail: (@photo.video_preview.attached? ? "#{base}/thumbnail" : nil),
        video: (@photo.video_display.attached? ? "#{base}/video" : nil) }
    else
      { thumbnail: "#{base}/thumbnail", display: "#{base}/display" }
    end
    paths[:original] = "#{base}/original" if @user.owner? && @photo.owner_id == @user.id
    paths
  end
end
