class NormalizeHeicPhotoContentTypes < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL.squish
      UPDATE photos
      SET content_type = CASE
        WHEN LOWER(original_filename) LIKE '%.heic' THEN 'image/heic'
        WHEN LOWER(original_filename) LIKE '%.heif' THEN 'image/heif'
        ELSE content_type
      END
      WHERE content_type LIKE 'video/%'
        AND (
          LOWER(original_filename) LIKE '%.heic'
          OR LOWER(original_filename) LIKE '%.heif'
        )
    SQL
  end

  def down
    # Content type repair is intentionally not reversible.
  end
end
