class UploadChunksController < ApplicationController
  UPLOAD_TTL = 30.minutes
  CHUNK_SIZE = 16.megabytes
  MAX_FILES_PER_UPLOAD = 1_000
  MAX_CHUNKS_PER_FILE = 4_096
  ID_PATTERN = /\A[a-zA-Z0-9][a-zA-Z0-9_-]{0,127}\z/
  owner_access_message "Only the owner can upload photos."

  before_action :require_owner!
  before_action :cleanup_stale_uploads, only: %i[create status complete]

  def create
    chunk = params.require(:chunk)
    unless chunk.respond_to?(:tempfile) && chunk.respond_to?(:size)
      raise ActionController::BadRequest, "Invalid upload chunk"
    end
    raise ActionController::BadRequest, "Upload chunk is too large" if chunk.size > CHUNK_SIZE

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
    result = PhotoImporter.new(owner: current_user, upload_batch: active_upload_batch).import(files)
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
      unless tempfile.size == manifest.fetch(:byte_size)
        raise ActionController::BadRequest, "Uploaded file size does not match the manifest"
      end

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
    validated_id(params.require(:upload_id), "upload")
  end

  def file_id
    validated_id(params.require(:file_id), "file")
  end

  def chunk_index
    integer_parameter(params.require(:chunk_index), "chunk index").tap do |index|
      raise ActionController::BadRequest, "Invalid chunk index" unless index.between?(0, MAX_CHUNKS_PER_FILE - 1)
    end
  end

  def file_manifests
    files = params.require(:files)
    unless files.is_a?(Array) && files.size.between?(1, MAX_FILES_PER_UPLOAD)
      raise ActionController::BadRequest, "Invalid file count"
    end

    manifests = files.map do |file|
      raise ActionController::BadRequest, "Invalid file manifest" unless file.respond_to?(:permit)

      file.permit(:file_id, :filename, :content_type, :byte_size, :total_chunks).to_h.symbolize_keys.tap do |manifest|
        manifest[:file_id] = validated_id(manifest.fetch(:file_id), "file")
        manifest[:filename] = validated_filename(manifest.fetch(:filename))
        manifest[:byte_size] = integer_parameter(manifest.fetch(:byte_size), "file size")
        manifest[:total_chunks] = integer_parameter(manifest.fetch(:total_chunks), "chunk count")
        validate_manifest!(manifest)
      end
    end

    raise ActionController::BadRequest, "Duplicate file id" unless manifests.map { |manifest| manifest[:file_id] }.uniq.size == manifests.size

    manifests
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
    root = resumable_upload_root
    return unless root.directory?

    cutoff = UPLOAD_TTL.ago
    root.children.each do |upload|
      FileUtils.rm_rf(upload) if upload.directory? && upload.mtime < cutoff
    end
  rescue Errno::ENOENT
    nil
  end

  def upload_dir(id)
    resumable_upload_root.join(validated_id(id, "upload"))
  end

  def resumable_upload_root
    path_parts = [ "tmp/resumable_uploads" ]
    path_parts << "test-#{Process.pid}" if Rails.env.test?
    path_parts << current_user.id.to_s

    Rails.root.join(*path_parts)
  end

  def upload_file_dir(id, file)
    upload_dir(id).join(validated_id(file, "file"))
  end

  def validated_id(value, label)
    value.to_s.tap do |id|
      raise ActionController::BadRequest, "Invalid #{label} id" unless ID_PATTERN.match?(id)
    end
  end

  def validated_filename(value)
    value.to_s.tap do |filename|
      valid = filename.present? && filename.bytesize <= 255 && File.basename(filename) == filename &&
        !filename.include?("\\") && !filename.match?(/[[:cntrl:]]/)
      raise ActionController::BadRequest, "Invalid filename" unless valid
    end
  end

  def integer_parameter(value, label)
    Integer(value)
  rescue ArgumentError, TypeError
    raise ActionController::BadRequest, "Invalid #{label}"
  end

  def validate_manifest!(manifest)
    byte_size = manifest.fetch(:byte_size)
    total_chunks = manifest.fetch(:total_chunks)
    expected_chunks = [ (byte_size.to_f / CHUNK_SIZE).ceil, 1 ].max

    raise ActionController::BadRequest, "Invalid file size" unless byte_size.between?(0, CHUNK_SIZE * MAX_CHUNKS_PER_FILE)
    raise ActionController::BadRequest, "Invalid chunk count" unless total_chunks.between?(1, MAX_CHUNKS_PER_FILE)
    raise ActionController::BadRequest, "Chunk count does not match file size" unless total_chunks == expected_chunks
  end

  def owner_access_json_response?
    true
  end

  def active_upload_batch
    UploadBatch.active_for(current_user)
  end
end
