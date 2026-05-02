class AddDimensionsToPhotoMetadata < ActiveRecord::Migration[8.1]
  def change
    add_column :photo_metadata, :width, :integer
    add_column :photo_metadata, :height, :integer
  end
end
