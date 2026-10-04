class PreparePhotoBookExportJob < ApplicationJob
  queue_as :default
  discard_on ActiveJob::DeserializationError
  # Book PDFs retain their compressed artwork while rendering. Serialize these
  # jobs across books so several large exports cannot overwhelm a small worker.
  limits_concurrency to: 1, key: ->(_export) { "photobook-pdf" }, duration: 1.hour

  def perform(export)
    # Duplicate delivery must not overwrite a completed export or attach twice.
    export.with_lock do
      return if export.ready?

      export.update!(status: "processing", error: nil, processed_pages: 0)
    end
    path = PhotoBookPdfExporter.new(export, progress: ->(count) { export.update!(processed_pages: count) }).export
    # Upload before publishing the attachment so a ready export is immediately
    # downloadable, including on remote Active Storage services.
    blob = File.open(path, "rb") do |file|
      ActiveStorage::Blob.create_and_upload!(io: file, filename: export.filename, content_type: "application/pdf")
    end
    export.with_lock do
      raise PhotoBookPdfExporter::InvalidDesign, "A source photo is no longer available." unless export.source_photos_available?

      export.document.attach(blob)
      export.update!(status: "ready")
    end
  rescue ActiveRecord::RecordNotFound
    # Removing a book also removes its pending exports.
    blob&.purge
    nil
  rescue StandardError => error
    export.document.purge if export.document.attached?
    blob.purge if blob && blob.attachments.empty?
    return if export.destroyed? || !PhotoBookExport.exists?(export.id)

    # Filesystem paths, original filenames, and internal storage errors should
    # never be copied into an owner-facing error or a persisted design.
    message = error.is_a?(PhotoBookPdfExporter::InvalidDesign) ? error.message.truncate(500) : "The PDF could not be generated. Check that the original photos are available, then try again."
    export.update!(status: "failed", error: message)
    raise unless error.is_a?(PhotoBookPdfExporter::InvalidDesign)
  ensure
    FileUtils.rm_f(path) if path
  end
end
