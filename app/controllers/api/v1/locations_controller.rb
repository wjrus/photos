module Api
  module V1
    class LocationsController < BaseController
      before_action :require_metadata_access!

      def index
        page = params[:page].present? ? Integer(params[:page]) : 1
        raise ActionController::BadRequest unless page.between?(1, 100_000)
        scope = photo_scope.joins(:metadata).merge(PhotoMetadata.geotagged)
        groups = PhotoLocation.groups(scope, limit: page_limit + 1, offset: (page - 1) * page_limit)
        render json: { locations: groups.first(page_limit).map { |group|
          { id: group.id, title: group.title, photo_count: group.photo_count, latitude: group.latitude.to_f,
            longitude: group.longitude.to_f, photos_path: api_v1_photos_path(place_id: group.id) }
        }, page: page, has_more: groups.size > page_limit }
      end
    end
  end
end
