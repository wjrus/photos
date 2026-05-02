class AddVisibilityToPhotoAlbums < ActiveRecord::Migration[8.1]
  def change
    add_column :photo_albums, :visibility, :string, null: false, default: "private"
    add_column :photo_albums, :published_at, :datetime
    add_index :photo_albums, :visibility
    add_index :photo_albums, :published_at
  end
end
