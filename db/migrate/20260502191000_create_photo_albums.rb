class CreatePhotoAlbums < ActiveRecord::Migration[8.1]
  def change
    create_table :photo_albums do |t|
      t.references :owner, null: false, foreign_key: { to_table: :users }
      t.string :title, null: false
      t.string :source, null: false, default: "manual"
      t.string :source_path
      t.jsonb :raw, null: false, default: {}

      t.timestamps
    end

    add_index :photo_albums, [ :owner_id, :source, :source_path ], unique: true
  end
end
