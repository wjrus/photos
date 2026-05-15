class AddShowStreamMetadataToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :show_stream_metadata, :boolean, default: false, null: false
  end
end
