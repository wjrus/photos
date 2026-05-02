class CreatePhotoAlbumMemberships < ActiveRecord::Migration[8.1]
  def change
    create_table :photo_album_memberships do |t|
      t.references :photo, null: false, foreign_key: true
      t.references :photo_album, null: false, foreign_key: true

      t.timestamps
    end

    add_index :photo_album_memberships, [ :photo_id, :photo_album_id ], unique: true
  end
end
