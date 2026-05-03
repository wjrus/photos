class AddAccountFieldsToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :password_digest, :string
    add_column :users, :remember_token_digest, :string
    add_column :users, :invited_at, :datetime
    add_column :users, :invite_accepted_at, :datetime
    add_reference :users, :invited_by, foreign_key: { to_table: :users }

    remove_index :users, :email
    add_index :users, :email, unique: true
    add_index :users, :remember_token_digest
  end
end
