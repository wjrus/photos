class CreateDriveArchiveObjects < ActiveRecord::Migration[8.1]
  def change
    create_table :drive_archive_objects do |t|
      t.references :photo, null: false, foreign_key: true, index: false
      t.string :status, null: false, default: "pending"
      t.string :google_file_id
      t.string :google_md5_checksum
      t.bigint :google_size
      t.text :error
      t.datetime :archived_at
      t.datetime :verified_at

      t.timestamps
    end

    add_index :drive_archive_objects, :photo_id, unique: true
    add_index :drive_archive_objects, :status
    add_index :drive_archive_objects, :google_file_id
  end
end
