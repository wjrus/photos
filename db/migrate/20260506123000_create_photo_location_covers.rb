class CreatePhotoLocationCovers < ActiveRecord::Migration[8.1]
  def change
    create_table :photo_location_covers do |t|
      t.references :owner, null: false, foreign_key: { to_table: :users }
      t.string :location_id, null: false
      t.references :cover_photo, null: false, foreign_key: { to_table: :photos }

      t.timestamps
    end

    add_index :photo_location_covers, [ :owner_id, :location_id ], unique: true
  end
end
