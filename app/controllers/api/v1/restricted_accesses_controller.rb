module Api
  module V1
    class RestrictedAccessesController < BaseController
      before_action :require_owner!
      rate_limit to: 10, within: 15.minutes, only: :create, by: -> { current_user.id },
        with: -> { api_error("rate_limited", "Too many unlock attempts.", :too_many_requests) }

      def create
        configured = ENV["PHOTOS_LOCKED_FOLDER_PASSWORD"].to_s
        supplied = params.require(:password).to_s
        unless configured.present? && ActiveSupport::SecurityUtils.secure_compare(User.digest(configured), User.digest(supplied))
          @device.update!(restricted_unlocked_until: nil, restricted_password_digest: nil)
          return api_error("invalid_credentials", "Locked-folder password was not recognized.", :unauthorized)
        end
        @device.update!(restricted_unlocked_until: 15.minutes.from_now, restricted_password_digest: User.digest(configured))
        render json: { unlocked_until: @device.restricted_unlocked_until }
      end

      def destroy
        @device.update!(restricted_unlocked_until: nil, restricted_password_digest: nil)
        head :no_content
      end
    end
  end
end
