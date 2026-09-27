class CreatePhotoPlaces < ActiveRecord::Migration[8.1]
  def change
    create_table :photo_places do |t|
      t.string :identity_key, null: false
      t.string :name, null: false
      t.jsonb :names, null: false, default: []
      t.string :provider
      t.string :provider_place_id
      t.string :place_type
      t.string :map_region_key
      t.string :map_region_name
      t.decimal :latitude, precision: 10, scale: 6
      t.decimal :longitude, precision: 10, scale: 6
      t.jsonb :raw, null: false, default: {}
      t.datetime :geocoded_at
      t.timestamps
    end
    add_index :photo_places, :identity_key, unique: true
    add_index :photo_places, :names, using: :gin
    add_column :photo_metadata, :photo_place_id, :bigint
    add_column :photo_metadata, :location_source, :string
    add_foreign_key :photo_metadata, :photo_places, validate: false
    add_check_constraint :photo_metadata, "location_source IN ('automatic', 'manual')", name: "photo_metadata_location_source", validate: false
  end
end
