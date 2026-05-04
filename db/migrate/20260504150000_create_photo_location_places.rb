class CreatePhotoLocationPlaces < ActiveRecord::Migration[8.1]
  def change
    create_table :photo_location_places do |t|
      t.string :location_id, null: false
      t.string :name, null: false
      t.decimal :latitude, precision: 10, scale: 6
      t.decimal :longitude, precision: 10, scale: 6
      t.jsonb :raw, null: false, default: {}
      t.datetime :geocoded_at

      t.timestamps
    end

    add_index :photo_location_places, :location_id, unique: true
  end
end
