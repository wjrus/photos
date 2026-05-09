class CreateFileHealthChecks < ActiveRecord::Migration[8.1]
  def change
    create_table :file_health_checks do |t|
      t.references :photo, null: false, foreign_key: true
      t.references :active_storage_blob, null: false, foreign_key: { to_table: :active_storage_blobs }, index: false
      t.string :blob_key, null: false
      t.string :status, null: false
      t.bigint :expected_byte_size
      t.bigint :actual_byte_size
      t.string :expected_checksum_md5
      t.string :actual_checksum_md5
      t.string :expected_checksum_sha256
      t.string :actual_checksum_sha256
      t.text :error
      t.datetime :checked_at, null: false
      t.datetime :healed_at

      t.timestamps
    end

    add_index :file_health_checks, :active_storage_blob_id
    add_index :file_health_checks, :blob_key
    add_index :file_health_checks, :status
    add_index :file_health_checks, :checked_at
    add_index :file_health_checks, [ :photo_id, :checked_at ]
  end
end
