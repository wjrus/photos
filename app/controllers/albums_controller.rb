class AlbumsController < ApplicationController
  include PhotoStreamPagination
  owner_access_message "Only the owner can manage albums."

  before_action :require_owner!, except: %i[index show]
  before_action :set_visible_album, only: %i[show]
  before_action :set_album, only: %i[update publish unpublish destroy]

  def index
    @albums = PhotoAlbum.visible_to(current_user)
      .includes(:cover_photo)
      .display_order
      .to_a

    album_payload = cached_album_index_payload(@albums)
    @public_album_count = album_payload.fetch(:public_album_count)
    @private_album_count = album_payload.fetch(:private_album_count)
    @visible_media_counts = album_payload.fetch(:visible_media_counts)
    @album_covers = album_covers_from_ids(album_payload.fetch(:cover_photo_ids))
  end

  def show
    visible_photos = @album.photos
      .with_original_variant_records
      .visible_to(current_user)
      .stream_order

    @photos, @next_cursor = paginate_photo_stream(visible_photos)
    @visible_media_count = visible_media_counts_for([ @album ]).fetch(@album.id, { photos: 0, videos: 0 })
    @albums = current_user.photo_albums.display_order if current_user&.owner?

    render_photo_page_if_requested(
      return_to: album_path(@album),
      bulk_form_id: "album-photo-bulk-form",
      album: @album,
      group_by_day: false,
      next_page_path: album_path(@album)
    )
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
    redirect_to album_path(@album), notice: "Album returned to private."
  end

  def destroy
    @album.destroy!
    redirect_to albums_path, notice: "Album removed."
  end

  private

  def album_params
    params.require(:photo_album).permit(:title, :visibility)
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
      PhotoAlbumMembership.maximum(:created_at)&.utc&.to_i,
      PhotoAlbumMembership.count,
      Photo.maximum(:updated_at)&.utc&.to_i,
      albums.map(&:id)
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
end
