class AddArchivedAtIndexToPhotos < ActiveRecord::Migration[8.1]
  def change
    add_index :photos, :archived_at, if_not_exists: true
  end
end
