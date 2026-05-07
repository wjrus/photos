class NullifyGoogleTakeoutImportsOnPhotoDelete < ActiveRecord::Migration[8.1]
  def change
    remove_foreign_key :google_takeout_imports, :photos
    add_foreign_key :google_takeout_imports, :photos, on_delete: :nullify
  end
end
