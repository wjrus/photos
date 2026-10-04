module Api
  module V1
    class DevicesController < BaseController
      def index
        devices = current_user.device_sessions.order(id: :desc)
        devices = devices.where("id < ?", Integer(params[:before_id])) if params[:before_id].present?
        rows = devices.limit(page_limit + 1).to_a
        render json: { devices: rows.first(page_limit).map { |device|
          { id: device.id, name: device.name, platform: device.platform, created_at: device.created_at,
            last_used_at: device.last_used_at, expires_at: device.expires_at,
            revoked_at: device.revoked_at, current: device.id == @device.id }
        }, has_more: rows.size > page_limit, next_before_id: rows.first(page_limit).last&.id }
      end

      def destroy
        current_user.device_sessions.find(params[:id]).revoke!
        head :no_content
      end
    end
  end
end
