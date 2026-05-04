class AddHotPathIndexes < ActiveRecord::Migration[8.1]
  def change
    add_index :photos,
      %i[captured_at created_at id],
      order: { captured_at: :desc, created_at: :desc, id: :desc },
      where: "restricted = false AND archived_at IS NULL",
      name: "index_photos_on_visible_stream_order"

    add_index :photos,
      %i[captured_at created_at id],
      order: { captured_at: :desc, created_at: :desc, id: :desc },
      where: "visibility = 'public' AND restricted = false AND archived_at IS NULL",
      name: "index_photos_on_public_stream_order"

    add_index :photos, :updated_at
    add_index :photo_albums, :updated_at
    add_index :photo_album_memberships, :created_at
  end
end
