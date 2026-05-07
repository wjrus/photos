class CreateAlbumDownloads < ActiveRecord::Migration[8.1]
  def change
    create_table :album_downloads do |t|
      t.references :photo_album, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.string :status, null: false, default: "pending"
      t.string :filename, null: false
      t.string :zip_path
      t.integer :total_entries, null: false, default: 0
      t.integer :processed_entries, null: false, default: 0
      t.text :error

      t.timestamps
    end

    add_index :album_downloads, [ :user_id, :created_at ]
    add_index :album_downloads, :status
  end
end
