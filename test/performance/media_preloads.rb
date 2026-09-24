# Run with: RAILS_ENV=test rbenv exec bundle exec rails runner test/performance/media_preloads.rb
# Synthetic database records only, rolled back afterward; no media files are written.
abort "Run this benchmark only in the test environment" unless Rails.env.test?

module MediaPreloadBenchmark
  def self.blob(filename, content_type)
    ActiveStorage::Blob.create!(
      filename: filename, content_type: content_type, byte_size: 1,
      checksum: Base64.strict_encode64(Digest::MD5.digest("x")), service_name: "test"
    )
  end

  def self.attach(record, name, blob)
    ActiveStorage::Attachment.create!(record: record, name: name, blob: blob)
  end

  def self.seed
    token = SecureRandom.hex(8)
    owner = User.create!(provider: "password", uid: token, email: "#{token}@example.invalid", role: "owner")
    now = Time.current
    ids = Photo.insert_all!(60.times.map do |index|
      {
        owner_id: owner.id, title: "Synthetic media #{index}",
        content_type: index < 40 ? "image/jpeg" : "video/mp4",
        original_filename: index < 40 ? "synthetic.jpg" : "synthetic.mp4",
        created_at: now, updated_at: now
      }
    end).rows.flatten
    PhotoMetadata.insert_all!(ids.map do |id|
      { photo_id: id, width: 4032, height: 3024, latitude: 40, longitude: -80,
        raw: { synthetic_exif: "x" * 50_000 }, created_at: now, updated_at: now }
    end)

    Photo.where(id: ids).each do |photo|
      original = blob(photo.original_filename, photo.content_type)
      attach(photo, "original", original)
      if photo.image?
        %w[stream display].each do |name|
          variant = original.variant_records.create!(variation_digest: "synthetic-#{name}")
          attach(variant, "image", blob("#{name}.jpg", "image/jpeg"))
        end
      else
        attach(photo, "video_preview", blob("preview.jpg", "image/jpeg"))
        attach(photo, "video_display", blob("display.mp4", "video/mp4"))
      end
    end
    ids
  end

  def self.measure(scope, metadata_association)
    counts = Hash.new(0)
    queries = 0
    records = ->(event) { counts[event.payload[:class_name]] += event.payload[:record_count] }
    sql = lambda do |event|
      queries += 1 if event.payload[:name] != "SCHEMA" && event.payload[:sql].start_with?("SELECT")
    end
    photos = nil
    ActiveSupport::Notifications.subscribed(records, "instantiation.active_record") do
      ActiveSupport::Notifications.subscribed(sql, "sql.active_record") do
        photos = scope.to_a
      end
    end
    raw_bytes = photos.sum do |photo|
      photo.association(metadata_association).target.attributes_before_type_cast["raw"].to_s.bytesize
    end

    { queries: queries, records: counts, raw_exif_bytes: raw_bytes }
  end
end

ActiveRecord::Base.transaction do
  ids = MediaPreloadBenchmark.seed
  scopes = {
    "feed_before" => [ Photo.where(id: ids).with_attached_video_preview.with_attached_video_display.with_attached_original
      .includes(:metadata, original_attachment: { blob: { variant_records: { image_attachment: :blob } } }), :metadata ],
    "feed_after" => [ Photo.where(id: ids).with_original_variant_records, :display_metadata ],
    "map_before" => [ Photo.where(id: ids).with_attached_original.with_attached_video_preview.includes(:metadata), :metadata ],
    "map_after" => [ Photo.where(id: ids).includes(:display_metadata, :video_preview_attachment), :display_metadata ]
  }

  # Warm schema caches without reusing loaded relations or the query cache.
  ActiveRecord::Base.uncached do
    scopes.each_value { |scope, _metadata| scope.dup.load }
    results = scopes.transform_values { |scope, metadata| MediaPreloadBenchmark.measure(scope, metadata) }
    puts JSON.pretty_generate(results)
  end
  raise ActiveRecord::Rollback
end
