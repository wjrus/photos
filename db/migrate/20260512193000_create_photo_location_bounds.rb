class CreatePhotoLocationBounds < ActiveRecord::Migration[8.1]
  def change
    create_table :photo_location_bounds do |t|
      t.string :location_id, null: false
      t.decimal :south, precision: 10, scale: 6, null: false
      t.decimal :north, precision: 10, scale: 6, null: false
      t.decimal :west, precision: 10, scale: 6, null: false
      t.decimal :east, precision: 10, scale: 6, null: false
      t.integer :photo_count, null: false, default: 0
      t.datetime :calculated_at, null: false

      t.timestamps
    end

    add_index :photo_location_bounds, :location_id, unique: true
    add_index :photo_location_bounds, :calculated_at
  end
end
