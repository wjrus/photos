class AddNamesToPhotoLocationPlaces < ActiveRecord::Migration[8.1]
  def change
    add_column :photo_location_places, :names, :jsonb, null: false, default: []
    add_index :photo_location_places, :names, using: :gin
  end
end
