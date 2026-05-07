require "zip"

class AlbumZipExporter
  MAX_STALE_AGE = 6.hours

  attr_reader :filename

  def initialize(album:, photos:, progress: nil)
    @album = album
    @photos = photos
    @progress = progress
    @filename = "#{safe_album_name}-album.zip"
  end

  def export
    cleanup_stale_files

    zip_path = self.class.export_directory.join("#{SecureRandom.hex(16)}.zip")

    Zip::File.open(zip_path.to_s, create: true) do |zip|
      @photos.each.with_index(1) do |photo, index|
        next unless photo.original.attached?

        zip.get_output_stream(entry_name_for(photo, index)) do |entry|
          photo.original.blob.download { |chunk| entry.write(chunk) }
        end
        @progress&.call(index)
      end
    end

    zip_path
  end

  def self.export_directory
    Rails.root.join("tmp", "album-downloads").tap { |directory| FileUtils.mkdir_p(directory) }
  end

  private

  def cleanup_stale_files
    cutoff = MAX_STALE_AGE.ago

    self.class.export_directory.glob("*.zip").each do |path|
      FileUtils.rm_f(path) if path.mtime < cutoff
    rescue Errno::ENOENT
      next
    end
  end

  def safe_album_name
    @album.title.to_s.parameterize.presence || "album-#{@album.id}"
  end

  def entry_name_for(photo, index)
    original_name = photo.original.filename.to_s.presence || photo.original_filename.presence || "photo-#{photo.id}"
    safe_name = File.basename(original_name).gsub(/[^\w.\-()+ ]+/, "_").squish.presence || "photo-#{photo.id}"

    format("%04d-%s", index, safe_name)
  end
end
