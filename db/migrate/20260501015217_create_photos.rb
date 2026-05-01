class CreatePhotos < ActiveRecord::Migration[8.1]
  def change
    create_table :photos do |t|
      t.references :owner, null: false, foreign_key: { to_table: :users }
      t.string :title
      t.text :description
      t.string :visibility, null: false, default: "private"
      t.datetime :captured_at
      t.string :checksum_sha256
      t.string :original_filename
      t.string :content_type
      t.bigint :byte_size
      t.datetime :published_at
      t.datetime :archived_at

      t.timestamps
    end

    add_index :photos, :visibility
    add_index :photos, :captured_at
    add_index :photos, :published_at
  end
end
