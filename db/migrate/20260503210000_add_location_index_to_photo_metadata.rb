class AddLocationIndexToPhotoMetadata < ActiveRecord::Migration[8.1]
  def change
    add_index :photo_metadata,
      [ :latitude, :longitude ],
      name: "index_photo_metadata_on_location",
      where: "latitude IS NOT NULL AND longitude IS NOT NULL"
  end
end
