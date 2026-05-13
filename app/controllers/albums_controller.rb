class AlbumsController < ApplicationController
  include PhotoStreamPagination
  owner_access_message "Only the owner can manage albums."

  ALBUM_SORT_OPTIONS = {
    "letters" => "letters",
    "photos" => "photos"
  }.freeze
  ALBUM_PAGE_SIZE = 12

  before_action :require_owner!, except: %i[index show]
  before_action :set_visible_album, only: %i[show]
  before_action :set_album, only: %i[update publish unpublish destroy]

  def index
    @album_sort_options = ALBUM_SORT_OPTIONS
    @album_sort = album_sort_param
    @albums = PhotoAlbum.visible_to(current_user)
      .includes(:cover_photo)
      .display_order
      .to_a

    album_payload = cached_album_index_payload(@albums)
    @public_album_count = album_payload.fetch(:public_album_count)
    @private_album_count = album_payload.fetch(:private_album_count)
    @visible_media_counts = album_payload.fetch(:visible_media_counts)
    sorted_albums = sorted_albums(@albums, @visible_media_counts)
    @album_count = sorted_albums.size
    @album_page = [ params[:page].to_i, 1 ].max
    @albums = sorted_albums.slice((@album_page - 1) * ALBUM_PAGE_SIZE, ALBUM_PAGE_SIZE) || []
    @next_album_page = @album_page + 1 if @album_page * ALBUM_PAGE_SIZE < @album_count
    @album_covers = album_covers_from_ids(album_payload.fetch(:cover_photo_ids).slice(*@albums.map(&:id)))

    render partial: "albums/page", locals: { albums: @albums }, layout: false if @album_page > 1
  end

  def show
    visible_photos = @album.photos
      .with_original_variant_records
      .visible_to(current_user)
      .chronological_order

    @photos, @next_cursor, @newer_cursor = paginate_chronological_photo_stream_with_focus(visible_photos)
    @newer_cursor ||= chronological_timeline_previous_cursor(visible_photos) if params[:timeline_page].present?

    return if render_photo_page_if_requested(
      return_to: album_path(@album),
      bulk_form_id: "album-photo-bulk-form",
      album: @album,
      group_by_day: false,
      next_page_path: album_path(@album),
      stream_target_photo_id: @stream_target_photo_id
    )

    @visible_media_count = visible_media_counts_for([ @album ]).fetch(@album.id, { photos: 0, videos: 0 })
    if current_user&.owner?
      @albums = current_user.photo_albums.display_order
      @album_shares = @album.photo_album_shares.joins(:user).includes(:user).order(Arel.sql("LOWER(users.email) ASC"))
      @shareable_users = shareable_users_for(@album)
    end
    @timeline_periods = stream_timeline_periods(
      visible_photos,
      cache_key: album_timeline_cache_key(@album, visible_photos),
      order: :chronological
    ) unless params[:cursor].present?
  end

  def create
    @album = current_user.photo_albums.new(album_params.merge(source: "manual"))
    @album.published_at = Time.current if @album.public?

    if @album.save
      redirect_to album_path(@album), notice: "Album created."
    else
      redirect_to albums_path, alert: @album.errors.full_messages.to_sentence
    end
  end

  def update
    if @album.update(album_params)
      @album.update!(published_at: @album.public? ? (@album.published_at || Time.current) : nil)
      redirect_to album_path(@album), notice: "Album updated."
    else
      redirect_to album_path(@album), alert: @album.errors.full_messages.to_sentence
    end
  end

  def publish
    @album.publish!
    redirect_to album_path(@album), notice: "Album published."
  end

  def unpublish
    @album.unpublish!
    redirect_to album_path(@album), notice: "Album unpublished."
  end

  def destroy
    @album.destroy!
    redirect_to albums_path, notice: "Album removed."
  end

  private

  def album_params
    params.require(:photo_album).permit(:title, :visibility)
  end

  def album_sort_param
    sort = params[:sort].to_s
    ALBUM_SORT_OPTIONS.key?(sort) ? sort : "letters"
  end

  def sorted_albums(albums, media_counts)
    case @album_sort
    when "photos"
      albums.sort_by do |album|
        counts = media_counts.fetch(album.id, { photos: 0, videos: 0 })
        total_visible_media = counts.fetch(:photos, 0).to_i + counts.fetch(:videos, 0).to_i
        [ -total_visible_media, album.title.to_s.downcase, album.id ]
      end
    else
      albums
    end
  end

  def set_visible_album
    @album = PhotoAlbum.visible_to(current_user).find(params[:id])
  end

  def set_album
    @album = current_user.photo_albums.find(params[:id])
  end

  def visible_media_counts_for(albums)
    album_ids = albums.map(&:id)
    return {} if album_ids.empty?

    PhotoAlbumMembership
      .joins(:photo)
      .where(photo_album_id: album_ids)
      .merge(Photo.visible_to(current_user))
      .select(
        "photo_album_memberships.photo_album_id",
        "COUNT(*) FILTER (WHERE photos.content_type LIKE 'image/%') AS photo_count",
        "COUNT(*) FILTER (WHERE photos.content_type LIKE 'video/%') AS video_count"
      )
      .group(:photo_album_id)
      .each_with_object({}) do |row, counts|
        counts[row.photo_album_id] = { photos: row.photo_count.to_i, videos: row.video_count.to_i }
      end
  end

  def cached_album_index_payload(albums)
    Rails.cache.fetch(album_index_cache_key(albums), expires_in: 10.minutes, race_condition_ttl: 10.seconds) do
      {
        public_album_count: albums.count(&:public?),
        private_album_count: albums.count(&:private?),
        visible_media_counts: visible_media_counts_for(albums),
        cover_photo_ids: cover_photo_ids_for(albums)
      }
    end
  end

  def album_index_cache_key(albums)
    [
      "album-index/v3",
      cache_audience_key,
      PhotoAlbum.maximum(:updated_at)&.utc&.to_i,
      PhotoAlbum.count,
      PhotoAlbumShare.maximum(:updated_at)&.utc&.to_i,
      PhotoAlbumShare.count,
      PhotoAlbumMembership.maximum(:created_at)&.utc&.to_i,
      PhotoAlbumMembership.count,
      Photo.maximum(:updated_at)&.utc&.to_i,
      albums.map(&:id)
    ]
  end

  def album_timeline_cache_key(album, visible_photos)
    [
      "album-timeline/v4",
      cache_audience_key,
      album.id,
      album.updated_at&.utc&.to_i,
      PhotoAlbumMembership.where(photo_album_id: album.id).maximum(:created_at)&.utc&.to_i,
      PhotoAlbumMembership.where(photo_album_id: album.id).count,
      PhotoAlbumShare.where(photo_album_id: album.id).maximum(:updated_at)&.utc&.to_i,
      PhotoAlbumShare.where(photo_album_id: album.id).count,
      stream_timeline_cache_fingerprint(visible_photos)
    ]
  end

  def cover_photo_ids_for(albums)
    cover_photos_for(albums).transform_values(&:id)
  end

  def album_covers_from_ids(cover_photo_ids)
    photos = Photo
      .with_original_variant_records
      .visible_to(current_user)
      .where(id: cover_photo_ids.values)
      .index_by(&:id)

    cover_photo_ids.transform_values { |photo_id| photos[photo_id] }.compact
  end

  def cover_photos_for(albums)
    album_ids = albums.map(&:id)
    return {} if album_ids.empty?

    covers_by_album_id = visible_explicit_album_covers(albums)
    missing_album_ids = album_ids - covers_by_album_id.keys

    fallback_album_covers(missing_album_ids).each do |photo|
      covers_by_album_id[photo.album_cover_album_id.to_i] ||= photo
    end

    covers_by_album_id
  end

  def visible_explicit_album_covers(albums)
    cover_ids = albums.filter_map(&:cover_photo_id)
    return {} if cover_ids.empty?

    visible_covers = Photo
      .with_original_variant_records
      .visible_to(current_user)
      .where(id: cover_ids)
      .index_by(&:id)

    albums.each_with_object({}) do |album, covers|
      cover = visible_covers[album.cover_photo_id]
      covers[album.id] = cover if cover
    end
  end

  def fallback_album_covers(album_ids)
    return Photo.none if album_ids.empty?

    Photo
      .with_original_variant_records
      .visible_to(current_user)
      .joins(:photo_album_memberships)
      .where(photo_album_memberships: { photo_album_id: album_ids })
      .select(<<~SQL.squish)
        DISTINCT ON (photo_album_memberships.photo_album_id)
        photos.*,
        photo_album_memberships.photo_album_id AS album_cover_album_id
      SQL
      .order(Arel.sql("photo_album_memberships.photo_album_id, photos.captured_at DESC NULLS LAST, photos.created_at DESC, photos.id DESC"))
  end

  def shareable_users_for(album)
    shared_user_ids = album.photo_album_shares.select(:user_id)

    User
      .where(role: "viewer")
      .where.not(invited_at: nil)
      .where.not(id: shared_user_ids)
      .order(Arel.sql("LOWER(email) ASC"))
  end
end
