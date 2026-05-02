require "json"
require "marcel"
require "tempfile"
require "zip"

class GoogleTakeoutImporter
  MEDIA_EXTENSIONS = %w[.heic .jpg .jpeg .png .mov .mp4].freeze
  SIDECAR_EXTENSIONS = %w[.json .aae].freeze

  def initialize(owner:, logger: Rails.logger)
    @owner = owner
    @logger = logger
  end

  def import_path(path)
    path = Pathname(path)
    zip_paths = path.directory? ? path.children.grep(/\.zip\z/i).sort : [ path ]

    zip_paths.each_with_object(summary_hash) do |zip_path, summary|
      import_zip(zip_path, summary)
    end
  end

  private

  attr_reader :owner, :logger

  def import_zip(zip_path, summary)
    logger.info("Google Takeout import: #{zip_path}")

    Zip::File.open(zip_path.to_s) do |zip_file|
      sidecars = sidecars_for(zip_file)
      album_metadata = album_metadata_for(zip_file)

      zip_file.each do |entry|
        next if entry.directory?

        if media_entry?(entry)
          import_media_entry(zip_path, entry, sidecars, album_metadata, summary)
        elsif sidecar_entry?(entry)
          summary[:sidecars] += 1
        else
          record_skipped(zip_path, entry)
          summary[:skipped] += 1
        end
      end
    end
  end

  def sidecars_for(zip_file)
    zip_file.each_with_object({}) do |entry, sidecars|
      next if entry.directory? || !sidecar_entry?(entry)

      basename = normalized_basename(entry.name)
      sidecars[basename] ||= []
      sidecars[basename] << entry
    end
  end

  def album_metadata_for(zip_file)
    zip_file.each_with_object({}) do |entry, metadata_by_path|
      next if entry.directory? || File.basename(entry.name) != "metadata.json"

      folder_path = File.dirname(entry.name)
      metadata_by_path[folder_path] = JSON.parse(entry.get_input_stream.read)
    rescue JSON::ParserError
      metadata_by_path[folder_path] = {}
    end
  end

  def import_media_entry(zip_path, entry, sidecars, album_metadata, summary)
    import_record = GoogleTakeoutImport.find_or_initialize_by(zip_path: zip_path.to_s, entry_name: entry.name)
    if import_record.persisted? && import_record.status.in?(%w[imported duplicate skipped])
      attach_album(import_record.photo, entry, album_metadata, summary) if import_record.photo
      return count_existing(import_record, summary)
    end

    with_entry_tempfile(entry) do |tempfile|
      sha256 = Digest::SHA256.file(tempfile.path).hexdigest
      duplicate_photo = Photo.find_by(checksum_sha256: sha256)

      import_record.assign_attributes(original_filename: File.basename(entry.name), sha256: sha256)

      if duplicate_photo
        attach_album(duplicate_photo, entry, album_metadata, summary)
        import_record.update!(status: "duplicate", photo: duplicate_photo, error: nil, imported_at: Time.current)
        summary[:duplicates] += 1
        return
      end

      photo = build_photo(entry, tempfile, sha256, sidecars)
      photo.save!
      apply_google_metadata(photo, google_metadata_for(entry, sidecars))
      attach_album(photo, entry, album_metadata, summary)

      import_record.update!(status: "imported", photo: photo, error: nil, imported_at: Time.current)
      summary[:imported] += 1
      logger.info("Imported #{entry.name} -> photo ##{photo.id}")
    end
  rescue StandardError => e
    import_record ||= GoogleTakeoutImport.find_or_initialize_by(zip_path: zip_path.to_s, entry_name: entry.name)
    import_record.update!(status: "failed", error: e.message)
    summary[:failed] += 1
    logger.error("Failed #{entry.name}: #{e.class}: #{e.message}")
  end

  def attach_album(photo, entry, album_metadata, summary)
    album_path = album_path_for(entry)
    return unless album_path

    metadata = album_metadata.fetch(album_path, {})
    album = PhotoAlbum.find_or_create_by!(owner: owner, source: "google_takeout", source_path: album_path) do |record|
      record.title = album_title(album_path, metadata)
      record.raw = metadata
    end
    membership = PhotoAlbumMembership.find_or_create_by!(photo: photo, photo_album: album)

    summary[:albums] += 1 if album.previously_new_record?
    summary[:album_memberships] += 1 if membership.previously_new_record?
  end

  def album_path_for(entry)
    parts = entry.name.split("/")
    google_photos_index = parts.index("Google Photos")
    return unless google_photos_index

    folder_parts = parts[(google_photos_index + 1)...-1]
    return if folder_parts.blank?

    parts[0..google_photos_index].concat(folder_parts).join("/")
  end

  def album_title(album_path, metadata)
    metadata["title"].presence || File.basename(album_path)
  end

  def build_photo(entry, tempfile, sha256, sidecars)
    google_metadata = google_metadata_for(entry, sidecars)
    photo = owner.photos.new(
      checksum_sha256: sha256,
      checksum_status: "complete",
      checksum_error: nil,
      checksum_checked_at: Time.current
    )
    attach_original(photo, entry, tempfile)
    attach_aae_sidecars(photo, entry, sidecars)
    photo.description = google_metadata["description"].presence
    captured_at = timestamp_from_google_metadata(google_metadata)
    photo.captured_at = captured_at if captured_at
    photo
  end

  def attach_original(photo, entry, tempfile)
    tempfile.rewind
    photo.original.attach(
      io: tempfile,
      filename: File.basename(entry.name),
      content_type: Marcel::MimeType.for(nil, name: entry.name)
    )
  end

  def attach_aae_sidecars(photo, entry, sidecars)
    sidecars_for_entry(entry, sidecars).select { |sidecar| File.extname(sidecar.name).casecmp?(".aae") }.each do |sidecar|
      with_entry_tempfile(sidecar) do |tempfile|
        tempfile.rewind
        photo.sidecars.attach(
          io: tempfile,
          filename: File.basename(sidecar.name),
          content_type: "application/xml"
        )
      end
    end
  end

  def apply_google_metadata(photo, metadata)
    return if metadata.blank?

    captured_at = timestamp_from_google_metadata(metadata)
    geo_data = usable_geo_data(metadata["geoDataExif"]) || usable_geo_data(metadata["geoData"])
    photo.update_columns(captured_at: captured_at, updated_at: Time.current) if captured_at

    photo_metadata = photo.metadata || photo.build_metadata
    photo_metadata.update!(
      extraction_status: photo_metadata.extraction_status.presence || "pending",
      captured_at: captured_at || photo_metadata.captured_at,
      latitude: geo_data&.fetch("latitude", nil) || photo_metadata.latitude,
      longitude: geo_data&.fetch("longitude", nil) || photo_metadata.longitude,
      raw: photo_metadata.raw.merge("google_takeout" => metadata).compact,
      extracted_at: photo_metadata.extracted_at
    )
  end

  def google_metadata_for(entry, sidecars)
    sidecar = sidecars_for_entry(entry, sidecars).find do |candidate|
      File.extname(candidate.name).casecmp?(".json")
    end
    return {} unless sidecar

    JSON.parse(sidecar.get_input_stream.read)
  rescue JSON::ParserError
    {}
  end

  def timestamp_from_google_metadata(metadata)
    timestamp = metadata.dig("photoTakenTime", "timestamp").presence ||
      metadata.dig("creationTime", "timestamp").presence
    return unless timestamp

    Time.zone.at(Integer(timestamp))
  rescue ArgumentError, TypeError
    nil
  end

  def usable_geo_data(data)
    return unless data.is_a?(Hash)

    latitude = data["latitude"].to_f
    longitude = data["longitude"].to_f
    return if latitude.zero? && longitude.zero?

    { "latitude" => latitude, "longitude" => longitude }
  end

  def with_entry_tempfile(entry)
    Tempfile.create([ "google-takeout-", File.extname(entry.name) ], binmode: true) do |tempfile|
      entry.get_input_stream { |input| IO.copy_stream(input, tempfile) }
      tempfile.rewind
      yield tempfile
    end
  end

  def media_entry?(entry)
    File.extname(entry.name).downcase.in?(MEDIA_EXTENSIONS)
  end

  def sidecar_entry?(entry)
    File.extname(entry.name).downcase.in?(SIDECAR_EXTENSIONS)
  end

  def sidecars_for_entry(entry, sidecars)
    sidecars[normalized_basename(entry.name)] || []
  end

  def normalized_basename(name)
    basename = File.basename(name).downcase
    basename = basename.delete_suffix(".supplemental-metadata.json")
    basename = basename.delete_suffix(".json")
    basename = basename.delete_suffix(".aae")
    MEDIA_EXTENSIONS.each { |extension| basename = basename.delete_suffix(extension) }
    basename.sub(/\A(img)_o(\d+)\z/, "\\1_e\\2")
  end

  def record_skipped(zip_path, entry)
    GoogleTakeoutImport.find_or_create_by!(zip_path: zip_path.to_s, entry_name: entry.name) do |import_record|
      import_record.original_filename = File.basename(entry.name)
      import_record.status = "skipped"
      import_record.imported_at = Time.current
    end
  end

  def count_existing(import_record, summary)
    case import_record.status
    when "imported" then summary[:already_imported] += 1
    when "duplicate" then summary[:duplicates] += 1
    when "skipped" then summary[:skipped] += 1
    end
  end

  def summary_hash
    {
      imported: 0,
      already_imported: 0,
      duplicates: 0,
      skipped: 0,
      sidecars: 0,
      albums: 0,
      album_memberships: 0,
      failed: 0
    }
  end
end
