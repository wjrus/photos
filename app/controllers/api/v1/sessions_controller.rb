module Api
  module V1
    class SessionsController < BaseController
      skip_before_action :authenticate_device!, only: %i[create refresh]
      rate_limit to: 10, within: 3.minutes, only: :create, name: "ip", with: -> { throttled }
      rate_limit to: 10, within: 15.minutes, only: :create, name: "email",
        by: -> { User.digest(params[:email].to_s.strip.downcase) }, with: -> { throttled(retry_after: 15.minutes) }
      rate_limit to: 30, within: 3.minutes, only: :refresh, with: -> { throttled }

      def create
        email, password = params.require(:email), params.require(:password)
        raise ActionController::BadRequest unless email.is_a?(String) && password.is_a?(String) && email.bytesize <= 254 && password.bytesize <= 1024
        user = User.authenticate_by_email(email, password)
        return api_error("invalid_credentials", "Email or password was not recognized.", :unauthorized) unless user

        device, credentials = DeviceSession.issue!(user: user, name: params.require(:device_name), platform: params.require(:platform))
        render json: credentials.merge(user: { id: user.id, name: user.display_name, role: user.role }), status: :created
      end

      def refresh
        token = params.require(:refresh_token).to_s
        return api_error("unauthorized", "Refresh token is invalid or expired.", :unauthorized) if token.bytesize > 256

        device = DeviceSession.includes(:user).find_by(refresh_token_digest: User.digest(token))
        return api_error("unauthorized", "Refresh token is invalid or expired.", :unauthorized) unless device

        device.with_lock do
          unless device.active? && ActiveSupport::SecurityUtils.secure_compare(device.refresh_token_digest, User.digest(token))
            return api_error("unauthorized", "Refresh token is invalid or expired.", :unauthorized)
          end
          render json: device.rotate_credentials!
        end
      end

      def destroy
        @device.revoke!
        head :no_content
      end

      private

      def throttled(retry_after: 3.minutes)
        response.set_header("Retry-After", retry_after.to_i.to_s)
        api_error("rate_limited", "Too many attempts. Try again later.", :too_many_requests)
      end
    end
  end
end
