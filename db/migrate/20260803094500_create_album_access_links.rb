class CreateAlbumAccessLinks < ActiveRecord::Migration[8.1]
  def change
    create_table :album_access_links do |t|
      t.references :photo_album, null: false, foreign_key: true
      t.references :created_by, null: false, foreign_key: { to_table: :users }
      t.string :label, null: false, default: "Share link"
      t.datetime :expires_at
      t.datetime :revoked_at
      t.bigint :access_count, null: false, default: 0
      t.datetime :last_accessed_at

      t.timestamps
    end

    add_index :album_access_links, [ :photo_album_id, :created_at ]
    add_index :album_access_links, :revoked_at
  end
end
