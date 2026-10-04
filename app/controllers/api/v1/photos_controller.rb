module Api
  module V1
    class PhotosController < BaseController
      before_action :require_owner!, only: %i[update destroy bulk]
      before_action :require_metadata_access!, only: :info

      def index
        page = query.page(limit: page_limit)
        render json: page.merge(photos: page[:photos].map { |photo| photo_payload(photo) })
      end

      def show
        render json: { photo: photo_payload(query.scope.find(params[:id]), detail: true) }
      end

      def info
        photo = query.scope.find(params[:id])
        render json: MobilePhotoPresenter.new(photo: photo, user: current_user, device: @device).info
      end

      def navigation
        photo = query.scope.find(params[:id])
        neighbors = query.neighbors(photo)
        render json: { photo_id: photo.id, order: query.order,
          previous: neighbors[:previous] && photo_payload(neighbors[:previous]),
          next: neighbors[:next] && photo_payload(neighbors[:next]) }
      end

      def timeline
        counts = query.scope.group(Arel.sql("DATE_TRUNC('month', COALESCE(photos.captured_at, photos.created_at))")).count
        render json: { periods: counts.sort_by { |date, _| date }.reverse.map { |date, count|
          { month: date.strftime("%Y-%m"), count: count }
        } }
      end

      def update
        photo = manageable_photos.find(params[:id])
        photo.update!(params.require(:photo).permit(:title, :description))
        render json: { photo: photo_payload(photo, detail: true) }
      end

      def destroy
        manageable_photos.find(params[:id]).destroy!
        head :no_content
      end

      def bulk
        ids = selected_ids(:photo_ids)
        photos = manageable_photos.where(id: ids).in_order_of(:id, ids).to_a
        raise ActiveRecord::RecordNotFound unless photos.size == ids.size

        result = PhotoBulkOperation.new(owner: current_user, photos: photos, action: params.require(:bulk_action), attributes: params).call
        render json: result
      rescue PhotoBulkOperation::InvalidAction => error
        api_error("invalid_action", error.message, :unprocessable_content)
      end

      def media_url
        photo = query.scope.find(params[:id])
        variant = params.require(:variant)
        raise ActionController::BadRequest unless MobileMediaGrant::VARIANTS.include?(variant)
        if variant == "original" && (!current_user.owner? || photo.owner_id != current_user.id)
          return api_error("forbidden", "Only the owner can download originals.", :forbidden)
        end
        ttl = params[:expires_in].present? ? Integer(params[:expires_in]) : MobileMediaGrant::TTL.to_i
        raise ActionController::BadRequest unless ttl.between?(60, MobileMediaGrant::MAX_TTL.to_i)
        token = MobileMediaGrant.issue(device: @device, photo: photo, variant: variant, ttl: ttl)
        render json: { url: media_api_v1_photo_url(photo, variant: variant, media_token: token), expires_at: ttl.seconds.from_now }
      end

      private

      def query
        @query ||= MobilePhotoQuery.new(scope: photo_scope, user: current_user, params: params)
      end
    end
  end
end
