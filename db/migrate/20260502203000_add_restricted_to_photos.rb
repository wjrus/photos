class AddRestrictedToPhotos < ActiveRecord::Migration[8.1]
  def change
    add_column :photos, :restricted, :boolean, null: false, default: false
    add_index :photos, :restricted
  end
end
