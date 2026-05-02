class AddCoverPhotoToPhotoAlbums < ActiveRecord::Migration[8.1]
  def change
    add_reference :photo_albums, :cover_photo, foreign_key: { to_table: :photos }
  end
end
