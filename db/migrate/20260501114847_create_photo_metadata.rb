class CreatePhotoMetadata < ActiveRecord::Migration[8.1]
  def change
    create_table :photo_metadata do |t|
      t.references :photo, null: false, foreign_key: true, index: false
      t.string :extraction_status, null: false, default: "pending"
      t.text :extraction_error
      t.datetime :captured_at
      t.string :camera_make
      t.string :camera_model
      t.string :lens_model
      t.integer :iso
      t.string :aperture
      t.string :exposure_time
      t.string :focal_length
      t.decimal :latitude, precision: 10, scale: 6
      t.decimal :longitude, precision: 10, scale: 6
      t.jsonb :raw, null: false, default: {}
      t.datetime :extracted_at

      t.timestamps
    end

    add_index :photo_metadata, :photo_id, unique: true
    add_index :photo_metadata, :extraction_status
  end
end
