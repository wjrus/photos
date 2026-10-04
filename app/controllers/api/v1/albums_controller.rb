module Api
  module V1
    class AlbumsController < BaseController
      MEDIA_SUMMARY_SQL = <<~SQL.squish.freeze
        photo_album_memberships.photo_album_id, COUNT(*) AS visible_count,
        MAX(CASE WHEN photos.id = photo_albums.cover_photo_id THEN photos.id END) AS visible_cover_id,
        (ARRAY_AGG(photos.id ORDER BY photos.captured_at DESC NULLS LAST, photos.created_at DESC, photos.id DESC))[1] AS representative_id
      SQL

      before_action :require_owner!, except: %i[index show]

      def index
        page = params[:page].present? ? Integer(params[:page]) : 1
        raise ActionController::BadRequest unless page.between?(1, 100_000)
        albums = PhotoAlbum.visible_to(current_user).display_order.offset((page - 1) * page_limit).limit(page_limit + 1).to_a
        render json: { albums: album_payloads(albums.first(page_limit)), page: page, has_more: albums.size > page_limit }
      end

      def show
        album = PhotoAlbum.visible_to(current_user).find(params[:id])
        render json: { album: payload(album), photos_path: api_v1_photos_path(album_id: album.id) }
      end

      def create
        album = current_user.photo_albums.new(album_params.merge(source: "manual"))
        album.published_at = Time.current if album.public?
        album.save!
        render json: { album: payload(album) }, status: :created
      end

      def update
        album = current_user.photo_albums.find(params[:id])
        album.assign_attributes(album_params)
        album.published_at = album.public? ? (album.published_at || Time.current) : nil
        album.save!
        render json: { album: payload(album) }
      end

      def destroy
        current_user.photo_albums.find(params[:id]).destroy!
        head :no_content
      end

      def bulk
        ids = selected_ids(:album_ids)
        albums = current_user.photo_albums.where(id: ids).to_a
        raise ActiveRecord::RecordNotFound unless albums.size == ids.size
        action = params.require(:bulk_action)
        raise ActionController::BadRequest unless %w[publish unpublish delete].include?(action)
        PhotoAlbum.transaction do
          albums.each { |album| action == "delete" ? album.destroy! : album.public_send("#{action}!") }
        end
        render json: { action: action, affected_count: albums.size }
      end

      def add_photos
        membership_operation("add_to_album", album_id: params[:id])
      end

      def remove_photos
        membership_operation("remove_from_album", context_album_id: params[:id])
      end

      def cover
        membership_operation("set_album_cover", context_album_id: params[:id])
      end

      private

      def album_params
        params.require(:album).permit(:title, :visibility)
      end

      def membership_operation(action, attributes)
        current_user.photo_albums.find(params[:id])
        ids = selected_ids(:photo_ids)
        photos = manageable_photos.where(id: ids).in_order_of(:id, ids).to_a
        raise ActiveRecord::RecordNotFound unless photos.size == ids.size
        render json: PhotoBulkOperation.new(owner: current_user, photos: photos, action: action, attributes: attributes).call
      rescue PhotoBulkOperation::InvalidAction => error
        api_error("invalid_action", error.message, :unprocessable_content)
      end

      def payload(album)
        album_payloads([ album ]).first
      end

      def album_payloads(albums)
        rows = PhotoAlbumMembership.joins(:photo, :photo_album).merge(Photo.visible_to(current_user))
          .where(photo_album_id: albums.map(&:id))
          .select(MEDIA_SUMMARY_SQL)
          .group(:photo_album_id).index_by(&:photo_album_id)
        cover_ids = rows.values.map { |row| row.visible_cover_id || row.representative_id }
        covers = Photo.where(id: cover_ids).includes(:display_metadata, :video_preview_attachment, :video_display_attachment).index_by(&:id)
        albums.map do |album|
          row = rows[album.id]
          cover = covers[row&.visible_cover_id || row&.representative_id]
          { id: album.id, title: album.title, visibility: album.visibility, updated_at: album.updated_at,
            photo_count: row&.visible_count.to_i, cover: cover && photo_payload(cover),
            manage: current_user.owner? && album.owner_id == current_user.id }
        end
      end
    end
  end
end
