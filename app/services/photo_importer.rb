class PhotoImporter
  def initialize(owner:, upload_batch: nil)
    @owner = owner
    @upload_batch = upload_batch
  end

  def import(files)
    files = Array(files).compact_blank
    sidecars, originals = files.partition { |file| sidecar_file?(file) }
    sidecars_by_basename = sidecars.group_by { |file| import_basename(file) }
    created = 0

    Photo.transaction do
      originals.each do |original|
        photo = owner.photos.new(upload_batch: upload_batch)
        photo.original.attach(original)
        Array(sidecars_by_basename[import_basename(original)]).each { |sidecar| photo.sidecars.attach(sidecar) }
        photo.save!
        created += 1
      end
    end

    { created: created, upload_batch: upload_batch }
  end

  private

  attr_reader :owner, :upload_batch

  def sidecar_file?(file)
    File.extname(original_filename(file)).casecmp?(".aae")
  end

  def import_basename(file)
    basename = File.basename(original_filename(file), ".*").downcase
    basename.sub(/\A(img)_o(\d+)\z/, "\\1_e\\2")
  end

  def original_filename(file)
    file.respond_to?(:original_filename) ? file.original_filename.to_s : file.to_s
  end
end
