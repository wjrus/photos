module Api
  module V1
    class MediaController < BaseController
      include ActionController::DataStreaming
      skip_before_action :authenticate_device!
      before_action :authenticate_media!

      def show
        variant = params[:variant]
        raise ActionController::BadRequest unless MobileMediaGrant::VARIANTS.include?(variant)
        scope = Photo.visible_to(current_user)
        scope = scope.or(current_user.photos.archived) if current_user.owner?
        scope = scope.or(current_user.photos.restricted) if @device.restricted_unlocked?
        photo = scope.find(params[:id])
        if variant == "original" && (!current_user.owner? || photo.owner_id != current_user.id)
          return api_error("forbidden", "Only the owner can download originals.", :forbidden)
        end
        blob = media_blob(photo, variant)
        return api_error("media_pending", "The media derivative is not ready.", :conflict) unless blob

        serve_blob(blob, photo: photo, variant: variant)
      end

      private

      def authenticate_media!
        if params[:media_token].present?
          @device = MobileMediaGrant.verify(params[:media_token], photo_id: params[:id], variant: params[:variant])
          return api_error("unauthorized", "Media link is invalid or expired.", :unauthorized) unless @device
          @current_user = @device.user
        else
          authenticate_device!
        end
      end

      def media_blob(photo, variant)
        case variant
        when "original" then photo.original.blob
        when "video" then photo.video_display.blob if photo.video_display.attached?
        when "thumbnail"
          if photo.video?
            photo.video_preview.blob if photo.video_preview.attached?
          else
            photo.original.variant(:stream).processed.image.blob
          end
        when "display"
          photo.original.variant(:display).processed.image.blob if photo.image?
        end
      end

      def serve_blob(blob, photo:, variant:)
        first, last = 0, blob.byte_size - 1
        response.set_header("Accept-Ranges", "bytes")
        if request.headers["Range"].present?
          match = request.headers["Range"].match(/\Abytes=(\d*)-(\d*)\z/)
          return invalid_range(blob) unless match && (match[1].present? || match[2].present?)
          if match[1].blank?
            return invalid_range(blob) unless match[2].to_i.positive?
            first = [ blob.byte_size - match[2].to_i, 0 ].max
          else
            first = match[1].to_i
            last = [ match[2].to_i, last ].min if match[2].present?
          end
          return invalid_range(blob) unless first <= last && first < blob.byte_size
          self.status = :partial_content
          response.set_header("Content-Range", "bytes #{first}-#{last}/#{blob.byte_size}")
        end
        response.set_header("Content-Type", blob.content_type || "application/octet-stream")
        response.set_header("Content-Length", (last - first + 1).to_s)
        extension = variant == "original" ? File.extname(photo.original_filename) : (photo.video? && variant == "video" ? ".mp4" : ".jpg")
        disposition = variant == "original" ? "attachment" : "inline"
        response.set_header("Content-Disposition", ActionDispatch::Http::ContentDisposition.format(disposition: disposition, filename: "photo-#{photo.id}#{extension}"))
        self.response_body = Enumerator.new do |stream|
          offset = first
          while offset <= last
            finish = [ offset + 1.megabyte - 1, last ].min
            stream << blob.download_chunk(offset..finish)
            offset = finish + 1
          end
        end
      end

      def invalid_range(blob)
        response.set_header("Content-Range", "bytes */#{blob.byte_size}")
        head :range_not_satisfiable
      end
    end
  end
end
