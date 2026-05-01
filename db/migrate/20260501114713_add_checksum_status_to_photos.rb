class AddChecksumStatusToPhotos < ActiveRecord::Migration[8.1]
  def change
    add_column :photos, :checksum_status, :string, null: false, default: "pending"
    add_column :photos, :checksum_error, :text
    add_column :photos, :checksum_checked_at, :datetime

    add_index :photos, :checksum_status
  end
end
