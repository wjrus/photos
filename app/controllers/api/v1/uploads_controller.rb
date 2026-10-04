module Api
  module V1
    class UploadsController < BaseController
      before_action :require_owner!
      around_action :cleanup_unattached_staging, only: %i[chunk file]
      rate_limit to: 120, within: 1.minute, only: :create,
        by: -> { @device.id }, with: -> { api_error("rate_limited", "Too many upload requests.", :too_many_requests) }

      def index
        uploads = @device.mobile_uploads.order(id: :desc)
        uploads = uploads.where("id < ?", Integer(params[:before_id])) if params[:before_id].present?
        rows = uploads.limit(page_limit + 1).to_a
        render json: { uploads: rows.first(page_limit).map { |upload| payload(upload) }, has_more: rows.size > page_limit,
          next_before_id: rows.first(page_limit).last&.id }
      end

      def create
        attributes = params.require(:upload).permit(:client_asset_id, :filename, :content_type, :byte_size, :checksum_sha256, :captured_at).to_h.symbolize_keys
        attributes[:byte_size] = Integer(attributes.fetch(:byte_size).to_s, 10)
        attributes[:captured_at] = attributes[:captured_at].present? ? Time.iso8601(attributes[:captured_at]).round(6) : nil
        @device.with_lock do
          existing = @device.mobile_uploads.find_by(client_asset_id: attributes[:client_asset_id])
          if existing
            comparable = attributes.except(:captured_at)
            unless comparable.all? { |key, value| existing.public_send(key) == value } && existing.captured_at == attributes[:captured_at]
              return api_error("asset_conflict", "This asset identifier already has a different upload manifest.", :conflict)
            end
            return render json: { upload: payload(existing) }
          end
          if @device.mobile_uploads.where(completed_at: nil).where("expires_at > ?", Time.current).count >= 1000
            return api_error("upload_limit", "Complete or cancel pending uploads before adding more.", :conflict)
          end
          upload = @device.mobile_uploads.create!(attributes.merge(expires_at: MobileUpload::TTL.from_now))
          render json: { upload: payload(upload) }, status: :created
        end
      rescue KeyError
        api_error("invalid_request", "An upload manifest is required.", :bad_request)
      end

      def show
        render json: { upload: payload(find_upload) }
      end

      def chunk
        upload = find_upload
        position = Integer(params[:position], 10)
        raise ActionController::BadRequest unless position.between?(0, upload.chunk_count - 1)
        upload.with_lock do
          return unavailable_upload(upload) if upload.completed_at || upload.expires_at.past?
          Tempfile.create("mobile-chunk", binmode: true) do |file|
            copy_request(file, limit: upload.expected_chunk_size(position))
            file.rewind
            part = upload.mobile_upload_chunks.find_or_initialize_by(position: position)
            part.data.attach(staging_blob(file, position))
            part.save!
          end
          render json: { upload: payload(upload) }
        end
      end

      def file
        upload = find_upload
        complete = params[:complete].presence || "true"
        raise ActionController::BadRequest unless %w[true false].include?(complete)
        upload.with_lock do
          return render json: { upload: payload(upload) } if upload.completed_at
          return unavailable_upload(upload) if upload.expires_at.past?
          Tempfile.create("mobile-file", binmode: true) do |file|
            copy_request(file, limit: upload.byte_size)
            file.rewind
            upload.chunk_count.times do |position|
              Tempfile.create("mobile-file-chunk", binmode: true) do |part_file|
                IO.copy_stream(file, part_file, upload.expected_chunk_size(position))
                part_file.rewind
                part = upload.mobile_upload_chunks.find_or_initialize_by(position: position)
                part.data.attach(staging_blob(part_file, position))
                part.save!
              end
            end
          end
        end
        upload.complete! if complete == "true"
        render json: { upload: payload(upload) }
      end

      def complete
        upload = find_upload
        upload.complete!
        render json: { upload: payload(upload) }
      end

      def destroy
        upload = find_upload
        upload.with_lock { upload.destroy! }
        head :no_content
      end

      private

      def staging_blob(file, position)
        blob = ActiveStorage::Blob.create_and_upload!(io: file, filename: "chunk-#{position}", content_type: "application/octet-stream", identify: false)
        (@staged_blobs ||= []) << blob
        blob
      end

      def cleanup_unattached_staging
        yield
      ensure
        Array(@staged_blobs).each do |blob|
          blob.purge unless ActiveStorage::Attachment.exists?(blob_id: blob.id)
        end
      end

      def find_upload
        @device.mobile_uploads.find(params[:id])
      end

      def unavailable_upload(upload)
        api_error(upload.completed_at ? "upload_completed" : "upload_expired", "This upload no longer accepts data.", :conflict)
      end

      def copy_request(file, limit:)
        if request.content_length && request.content_length > limit
          raise ActionController::BadRequest, "Upload body is too large"
        end
        total = 0
        while (bytes = request.body.read([ 1.megabyte, limit - total + 1 ].min))&.present?
          total += bytes.bytesize
          raise ActionController::BadRequest, "Upload body is too large" if total > limit
          file.write(bytes)
        end
        raise ActionController::BadRequest, "Upload body has the wrong size" unless total == limit
      end

      def payload(upload)
        photo = upload.photo
        visible = photo && (!photo.restricted? || @device.restricted_unlocked?)
        { id: upload.id, client_asset_id: upload.client_asset_id, filename: upload.filename,
          byte_size: upload.byte_size, checksum_sha256: upload.checksum_sha256,
          chunk_bytes: MobileUpload::CHUNK_BYTES, chunk_count: upload.chunk_count,
          received_chunks: upload.mobile_upload_chunks.order(:position).pluck(:position),
          expires_at: upload.expires_at, completed_at: upload.completed_at, duplicate: upload.duplicate,
          photo: (photo_payload(photo, detail: true) if visible) }
      end
    end
  end
end
