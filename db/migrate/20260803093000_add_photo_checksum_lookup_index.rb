class AddPhotoChecksumLookupIndex < ActiveRecord::Migration[8.1]
  def change
    add_index :photos,
      [ :owner_id, :checksum_sha256 ],
      name: "index_photos_on_owner_and_checksum",
      where: "checksum_sha256 IS NOT NULL"
  end
end
