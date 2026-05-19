class AddStreamTileSizeToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :stream_tile_size, :string, default: "medium", null: false
  end
end
