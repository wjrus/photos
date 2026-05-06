class NormalizeHeicBlobContentTypes < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL.squish
      UPDATE active_storage_blobs
      SET content_type = CASE
        WHEN LOWER(active_storage_blobs.filename) LIKE '%.heic' THEN 'image/heic'
        WHEN LOWER(active_storage_blobs.filename) LIKE '%.heif' THEN 'image/heif'
        ELSE active_storage_blobs.content_type
      END
      FROM active_storage_attachments
      INNER JOIN photos
        ON photos.id = active_storage_attachments.record_id
       AND active_storage_attachments.record_type = 'Photo'
       AND active_storage_attachments.name = 'original'
      WHERE active_storage_blobs.id = active_storage_attachments.blob_id
        AND active_storage_blobs.content_type LIKE 'video/%'
        AND (
          LOWER(active_storage_blobs.filename) LIKE '%.heic'
          OR LOWER(active_storage_blobs.filename) LIKE '%.heif'
        )
    SQL
  end

  def down
    # Content type repair is intentionally not reversible.
  end
end
