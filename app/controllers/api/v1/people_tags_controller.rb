module Api
  module V1
    class PeopleTagsController < BaseController
      before_action :require_owner!

      def index
        users = User.where.not(id: current_user.id).order(:id)
        users = users.where("id > ?", Integer(params[:after_id])) if params[:after_id].present?
        rows = users.limit(page_limit + 1).to_a
        render json: { people: rows.first(page_limit).map { |user| { id: user.id, name: user.display_name } },
          has_more: rows.size > page_limit, next_after_id: rows.first(page_limit).last&.id }
      end

      def create
        photo = manageable_photos.find(params[:photo_id])
        user = User.where.not(id: current_user.id).find(params.require(:user_id))
        tag = photo.photo_people_tags.find_or_create_by!(user: user) { |item| item.tagged_by = current_user }
        render json: { tag: { id: tag.id, user_id: user.id, name: user.display_name } }, status: :created
      end

      def destroy
        photo = manageable_photos.find(params[:photo_id])
        photo.photo_people_tags.find(params[:id]).destroy!
        head :no_content
      end
    end
  end
end
