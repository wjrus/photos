require "digest"
require "find"

class PhotoDirectoryImporter
  ImportFile = Data.define(:io, :original_filename, :content_type) do
    def active_storage_attachable
      { io: io, filename: original_filename, content_type: content_type }
    end
  end

  VIDEO_EXTENSIONS = %w[.3gp .avi .m4v .mkv .mov .mp4 .mpeg .mpg .webm].freeze
  SIDECAR_EXTENSION = ".aae"

  def initialize(owner:, logger: Rails.logger, output: nil, dry_run: false, verbose: false)
    raise ArgumentError, "Directory imports require an owner account" unless owner&.owner?

    @owner = owner
    @logger = logger
    @output = output
    @dry_run = dry_run
    @verbose = verbose
    @upload_batch = nil
  end

  def import_path(path)
    root = Pathname(path).expand_path
    raise ArgumentError, "Import directory does not exist: #{root}" unless root.directory?

    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    summary = empty_summary
    announce "Directory import #{dry_run ? "dry run" : "run"} starting."
    announce "Scanning #{root}..."
    paths = discover_paths(root, summary)
    sidecars = paths.select { |candidate| sidecar?(candidate) }.group_by { |candidate| pairing_key(root, candidate) }
    originals = paths.reject { |candidate| sidecar?(candidate) }
    summary[:discovered] = originals.size
    announce "Discovered #{originals.size} media files and #{sidecars.values.sum(&:size)} sidecars; #{summary[:ignored]} files ignored."

    originals.each_with_index do |original, index|
      matched_sidecars = sidecars.fetch(pairing_key(root, original), [])
      announce "[#{index + 1}/#{originals.size}] hashing #{relative_path(root, original)} (#{formatted_size(original.size)})"
      import_original(root, original, matched_sidecars, summary)
      log_progress(index + 1, originals.size, summary)
    end

    summary[:orphan_sidecars] = sidecars.values.sum(&:size) - summary[:sidecars]
    commit_upload_batch
    summary[:upload_batch_id] = upload_batch&.id
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
    announce "Finished scanning #{originals.size} media files in #{format("%.1f", elapsed)} seconds."
    summary
  rescue StandardError
    commit_upload_batch
    raise
  end

  private

  attr_reader :owner, :logger, :output, :dry_run, :verbose, :upload_batch

  def discover_paths(root, summary)
    paths = []

    Find.find(root.to_s) do |entry|
      path = Pathname(entry)
      if path != root && hidden?(path)
        Find.prune if path.directory?
        next
      end
      next unless path.file?

      if path.symlink? || !supported?(path)
        summary[:ignored] += 1
      else
        paths << path
      end
    end

    paths.sort_by { |path| path.to_s.downcase }
  end

  def import_original(root, original, matched_sidecars, summary)
    checksum = Digest::SHA256.file(original).hexdigest
    announce "  checking library for checksum #{checksum.first(12)}..."
    if duplicate_photo(checksum, original)
      summary[:duplicates] += 1
      announce "  duplicate; skipped"
      log("skip duplicate #{relative_path(root, original)}")
      return
    end

    if dry_run
      summary[:would_import] += 1
      summary[:sidecars] += matched_sidecars.size
      announce "  would import#{sidecar_suffix(matched_sidecars)}"
      log("would import #{relative_path(root, original)}")
      return
    end

    with_uploaded_files(original, matched_sidecars) do |uploaded_original, uploaded_sidecars|
      result = PhotoImporter.new(owner: owner, upload_batch: current_upload_batch).import(
        [ uploaded_original, *uploaded_sidecars ],
        checksums: { uploaded_original => checksum }
      )
      summary[:imported] += result.fetch(:created)
      summary[:sidecars] += uploaded_sidecars.size
    end
    announce "  imported#{sidecar_suffix(matched_sidecars)}"
    log("imported #{relative_path(root, original)}")
  rescue StandardError => error
    summary[:failed] += 1
    summary[:errors] << "#{relative_path(root, original)}: #{error.class}: #{error.message}"
    announce "  FAILED: #{error.class}: #{error.message}"
    logger.error("Directory import failed for #{original}: #{error.class}: #{error.message}")
  end

  def duplicate_photo(checksum, original)
    owner.photos.find_by(checksum_sha256: checksum) || pending_duplicate(checksum, original)
  end

  def pending_duplicate(checksum, original)
    owner.photos
      .where(checksum_sha256: nil, byte_size: original.size, original_filename: original.basename.to_s)
      .with_attached_original
      .find do |photo|
        matches = photo.original.blob.open { |file| Digest::SHA256.file(file).hexdigest == checksum }
        if matches
          photo.update!(checksum_sha256: checksum, checksum_status: "complete", checksum_checked_at: Time.current, checksum_error: nil)
        end
        matches
      end
  end

  def with_uploaded_files(original, sidecars)
    files = [ original, *sidecars ].map do |path|
      ImportFile.new(
        io: File.open(path, "rb"),
        original_filename: path.basename.to_s,
        content_type: content_type(path)
      )
    end
    yield files.first, files.drop(1)
  ensure
    Array(files).each { |file| file.io.close }
  end

  def content_type(path)
    return "application/xml" if sidecar?(path)

    Marcel::MimeType.for(path, name: path.basename.to_s)
  end

  def supported?(path)
    extension = path.extname.downcase
    extension == SIDECAR_EXTENSION || Photo::STILL_IMAGE_EXTENSIONS.include?(extension) || VIDEO_EXTENSIONS.include?(extension)
  end

  def sidecar?(path)
    path.extname.casecmp?(SIDECAR_EXTENSION)
  end

  def pairing_key(root, path)
    directory = path.dirname.relative_path_from(root).to_s.downcase
    basename = path.basename(".*").to_s.downcase.sub(/\A(img)_o(\d+)\z/, "\\1_e\\2")
    [ directory, basename ]
  end

  def hidden?(path)
    path.basename.to_s.start_with?(".")
  end

  def relative_path(root, path)
    path.relative_path_from(root)
  end

  def current_upload_batch
    @upload_batch ||= UploadBatch.create!(owner: owner)
  end

  def commit_upload_batch
    upload_batch&.commit! if upload_batch&.reviewing?
  end

  def log_progress(processed, total, summary)
    return unless verbose || (processed % 100).zero? || processed == total

    logger.info(
      "Directory import #{processed}/#{total}: " \
      "#{summary[:imported]} imported, #{summary[:duplicates]} duplicates, #{summary[:failed]} failed"
    )
  end

  def log(message)
    logger.info(message) if verbose
  end

  def announce(message)
    return unless output

    output.puts(message)
    output.flush
  end

  def formatted_size(bytes)
    units = %w[B KB MB GB TB]
    size = bytes.to_f
    unit = units.shift

    while size >= 1024 && units.any?
      size /= 1024
      unit = units.shift
    end

    size >= 10 || unit == "B" ? "#{size.round} #{unit}" : format("%.1f %s", size, unit)
  end

  def sidecar_suffix(sidecars)
    return "" if sidecars.empty?

    " with #{sidecars.size} sidecar#{"s" unless sidecars.one?}"
  end

  def empty_summary
    {
      discovered: 0,
      imported: 0,
      would_import: 0,
      duplicates: 0,
      sidecars: 0,
      orphan_sidecars: 0,
      ignored: 0,
      failed: 0,
      errors: [],
      upload_batch_id: nil
    }
  end
end
