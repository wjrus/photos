class CreatePhotoAlbumShares < ActiveRecord::Migration[8.1]
  def change
    create_table :photo_album_shares do |t|
      t.references :photo_album, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.references :shared_by, null: false, foreign_key: { to_table: :users }

      t.timestamps
    end

    add_index :photo_album_shares, [ :photo_album_id, :user_id ], unique: true
  end
end
