module Api
  module V1
    class BaseController < ActionController::API
      before_action :private_response
      before_action :authenticate_device!

      rescue_from ActiveRecord::RecordNotFound do
        api_error("not_found", "Resource not found.", :not_found)
      end
      rescue_from ActionController::ParameterMissing, ActionController::BadRequest, ActionDispatch::Http::Parameters::ParseError, ArgumentError, TypeError do
        api_error("invalid_request", "Invalid request parameters.", :bad_request)
      end
      rescue_from ActiveRecord::RecordInvalid do |error|
        api_error("validation_failed", error.record.errors.full_messages.to_sentence, :unprocessable_content)
      end

      private

      def private_response
        response.set_header("Cache-Control", "private, no-store")
        response.set_header("Referrer-Policy", "no-referrer")
        response.set_header("X-Content-Type-Options", "nosniff")
      end

      def authenticate_device!
        scheme, token = request.authorization.to_s.split(" ", 2)
        @device = DeviceSession.authenticate(token) if scheme&.casecmp?("Bearer")
        return api_error("unauthorized", "A valid device token is required.", :unauthorized) unless @device

        @current_user = @device.user
        @device.update_column(:last_used_at, Time.current) if @device.last_used_at.nil? || @device.last_used_at < 5.minutes.ago
      end

      attr_reader :current_user

      def require_owner!
        api_error("forbidden", "Only the owner can manage the library.", :forbidden) unless current_user.owner?
      end

      def require_metadata_access!
        api_error("forbidden", "Metadata access requires an accepted invitation.", :forbidden) unless current_user.trusted_viewer?
      end

      def api_error(code, message, status)
        render json: { error: { code: code, message: message } }, status: status
      end

      def page_limit
        params[:limit].present? ? Integer(params[:limit]).clamp(1, 100) : 60
      end

      def selected_ids(key)
        values = params.require(key)
        raise ActionController::BadRequest unless values.is_a?(Array) && values.size.between?(1, 200)

        values.map { |value| Integer(value.to_s, 10) }.uniq.tap do |ids|
          raise ActionController::BadRequest unless ids.all?(&:positive?)
        end
      end

      def photo_scope
        case params[:collection].presence || "library"
        when "library" then Photo.visible_to(current_user)
        when "public" then Photo.visible_to(current_user).publicly_visible
        when "archive"
          raise ActiveRecord::RecordNotFound unless current_user.owner?
          current_user.photos.archived
        when "restricted"
          raise ActiveRecord::RecordNotFound unless @device.restricted_unlocked?
          current_user.photos.restricted
        else
          raise ActionController::BadRequest
        end
      end

      def manageable_photos
        scope = current_user.photos
        @device.restricted_unlocked? ? scope : scope.where(restricted: false)
      end

      def photo_payload(photo, detail: false)
        MobilePhotoPresenter.new(photo: photo, user: current_user, device: @device).as_json(detail: detail)
      end
    end
  end
end
