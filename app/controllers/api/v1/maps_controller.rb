module Api
  module V1
    class MapsController < BaseController
      before_action :require_metadata_access!

      def show
        query = MobilePhotoQuery.new(scope: photo_scope.joins(:metadata).merge(PhotoMetadata.geotagged), user: current_user, params: params)
        scope = query.scope
        bounds = %i[north south east west].to_h do |key|
          value = params[key].present? ? Float(params[key]) : nil
          raise ActionController::BadRequest if value && (!value.finite? || value.abs > (%i[north south].include?(key) ? 90 : 180))
          [ key, value ]
        end
        raise ActionController::BadRequest if bounds.values.any? && !bounds.values.all?
        raise ActionController::BadRequest if bounds[:north] && bounds[:north] < bounds[:south]
        scope = scope.in_map_bounds(bounds) if bounds.values.all?
        page = MobilePhotoQuery.new(scope: scope, user: current_user, params: params.except(*PhotoSearch::FILTER_PARAMS, :album_id).merge(order: query.order)).page(limit: page_limit)
        render json: { markers: page[:photos].map { |photo|
          metadata = photo.display_metadata
          { photo: photo_payload(photo), latitude: metadata.latitude.to_f, longitude: metadata.longitude.to_f,
            location_id: PhotoLocation.id_for_metadata(metadata) }
        }, next_cursor: page[:next_cursor], has_more: page[:has_more] }
      end
    end
  end
end
