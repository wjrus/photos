class UploadChunksController < ApplicationController
  UPLOAD_TTL = 30.minutes

  before_action :require_owner!
  before_action :cleanup_stale_uploads, only: %i[create status complete]

  def create
    chunk = params.require(:chunk)
    file_dir = upload_file_dir(upload_id, file_id)
    FileUtils.mkdir_p(file_dir)
    FileUtils.cp(chunk.tempfile.path, file_dir.join(chunk_index.to_s))

    render json: { received: chunk_index }
  end

  def status
    render json: { files: chunk_statuses }
  end

  def complete
    files = assembled_files
    result = PhotoImporter.new(owner: current_user).import(files)
    flash[:notice] = "Uploaded #{result[:created]} private item#{'s' unless result[:created] == 1}."
    render json: { redirect_url: uploads_path }
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: e.record.errors.full_messages.to_sentence }, status: :unprocessable_content
  ensure
    cleanup_files(files)
    FileUtils.rm_rf(upload_dir(upload_id))
  end

  private

  def assembled_files
    file_manifests.map do |manifest|
      tempfile = Tempfile.new([ "photos-upload-", File.extname(manifest.fetch(:filename)) ], binmode: true)

      manifest.fetch(:total_chunks).times do |index|
        chunk_path = upload_file_dir(upload_id, manifest.fetch(:file_id)).join(index.to_s)
        raise ActionController::BadRequest, "Missing upload chunk #{index}" unless chunk_path.file?

        File.open(chunk_path, "rb") { |chunk| IO.copy_stream(chunk, tempfile) }
      end

      tempfile.rewind
      ActionDispatch::Http::UploadedFile.new(
        tempfile: tempfile,
        filename: manifest.fetch(:filename),
        type: manifest[:content_type].presence
      )
    end
  end

  def cleanup_files(files)
    Array(files).each do |file|
      file.tempfile.close!
    rescue IOError, SystemCallError
      nil
    end
  end

  def upload_id
    params.require(:upload_id).to_s
  end

  def file_id
    params.require(:file_id).to_s
  end

  def chunk_index
    Integer(params.require(:chunk_index))
  end

  def file_manifests
    params.require(:files).map do |file|
      file.permit(:file_id, :filename, :content_type, :byte_size, :total_chunks).to_h.symbolize_keys.tap do |manifest|
        manifest[:total_chunks] = Integer(manifest.fetch(:total_chunks))
      end
    end
  end

  def chunk_statuses
    file_manifests.to_h do |manifest|
      file_dir = upload_file_dir(upload_id, manifest.fetch(:file_id))
      chunks = existing_chunks(file_dir, manifest.fetch(:total_chunks))
      [ manifest.fetch(:file_id), chunks ]
    end
  end

  def existing_chunks(file_dir, total_chunks)
    return [] unless file_dir.directory?

    total_chunks.times.select do |index|
      file_dir.join(index.to_s).file?
    end
  end

  def cleanup_stale_uploads
    root = Rails.root.join("tmp/resumable_uploads", current_user.id.to_s)
    return unless root.directory?

    cutoff = UPLOAD_TTL.ago
    root.children.each do |upload|
      FileUtils.rm_rf(upload) if upload.directory? && upload.mtime < cutoff
    end
  end

  def upload_dir(id)
    safe_id = id.gsub(/[^a-zA-Z0-9_-]/, "")
    raise ActionController::BadRequest, "Invalid upload id" if safe_id.blank?

    Rails.root.join("tmp/resumable_uploads", current_user.id.to_s, safe_id)
  end

  def upload_file_dir(id, file)
    safe_file = file.gsub(/[^a-zA-Z0-9_-]/, "")
    raise ActionController::BadRequest, "Invalid file id" if safe_file.blank?

    upload_dir(id).join(safe_file)
  end

  def require_owner!
    return if current_user&.owner?

    render json: { error: "Only the owner can upload photos." }, status: :forbidden
  end
end
