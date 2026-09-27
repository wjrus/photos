class IndexAndValidatePhotoPlaces < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    index_name = "index_photo_metadata_on_photo_place_id"
    unless index_exists?(:photo_metadata, :photo_place_id, name: index_name, valid: true)
      remove_index :photo_metadata, name: index_name, algorithm: :concurrently if index_exists?(:photo_metadata, name: index_name)
      add_index :photo_metadata, :photo_place_id, name: index_name, algorithm: :concurrently
    end
    validate_foreign_key :photo_metadata, :photo_places
    validate_check_constraint :photo_metadata, name: "photo_metadata_location_source"
  end

  def down
    remove_index :photo_metadata, name: "index_photo_metadata_on_photo_place_id", algorithm: :concurrently
  end
end
