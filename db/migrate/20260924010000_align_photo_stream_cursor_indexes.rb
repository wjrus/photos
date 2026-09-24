class AlignPhotoStreamCursorIndexes < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  INDEX_SCOPES = {
    "visible" => "restricted = false AND archived_at IS NULL",
    "public" => "visibility = 'public' AND restricted = false AND archived_at IS NULL"
  }.freeze

  def up
    INDEX_SCOPES.each do |audience, condition|
      add_index :photos,
        "(CASE WHEN captured_at IS NULL THEN 0 ELSE 1 END) DESC, " \
        "COALESCE(captured_at, TIMESTAMP '0001-01-01') DESC, created_at DESC, id DESC",
        where: condition,
        name: "index_photos_on_#{audience}_stream_cursor",
        algorithm: :concurrently
    end

    # Keep the original indexes: their reverse scan matches oldest-first album
    # ordering, whose NULLS LAST behavior differs from the descending feed.
  end

  def down
    INDEX_SCOPES.each_key do |audience|
      remove_index :photos, name: "index_photos_on_#{audience}_stream_cursor", algorithm: :concurrently
    end
  end
end
