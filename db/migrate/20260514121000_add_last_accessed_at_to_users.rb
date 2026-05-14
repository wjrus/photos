class AddLastAccessedAtToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :last_accessed_at, :datetime
    add_index :users, :last_accessed_at
  end
end
