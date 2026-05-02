class CreateGoogleTakeoutImports < ActiveRecord::Migration[8.1]
  def change
    create_table :google_takeout_imports do |t|
      t.string :zip_path, null: false
      t.string :entry_name, null: false
      t.string :original_filename
      t.string :sha256
      t.string :status, null: false, default: "pending"
      t.text :error
      t.references :photo, foreign_key: true
      t.datetime :imported_at

      t.timestamps
    end

    add_index :google_takeout_imports, [ :zip_path, :entry_name ], unique: true
    add_index :google_takeout_imports, :sha256
    add_index :google_takeout_imports, :status
  end
end
