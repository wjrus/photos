module Api
  module V1
    class CapabilitiesController < BaseController
      skip_before_action :authenticate_device!, only: :show

      def show
        render json: { api_version: "1", authentication: { password: true, device_tokens: true,
          access_token_days: 30, refresh_token_days: 90, biometrics: "native_client" },
          features: { browsing: true, search: true, navigation: true, metadata: true, maps: true,
            albums: true, bulk_actions: PhotoBulkOperation::ACTIONS, album_bulk_actions: %w[publish unpublish delete],
            uploads: true, airplay: "native_client", scoped_media_urls: true },
          limits: { page_size: 100, bulk_selection: 200, upload_bytes: MobileUpload::MAX_BYTES,
            upload_chunk_bytes: MobileUpload::CHUNK_BYTES, upload_retention_days: 7,
            media_url_seconds: MobileMediaGrant::TTL.to_i, media_url_max_seconds: MobileMediaGrant::MAX_TTL.to_i } }
      end

      def me
        render json: { user: { id: current_user.id, name: current_user.display_name, role: current_user.role },
          permissions: { manage_library: current_user.owner?, upload: current_user.owner?,
            metadata: current_user.trusted_viewer?, restricted_unlocked: !!@device.restricted_unlocked? } }
      end
    end
  end
end
