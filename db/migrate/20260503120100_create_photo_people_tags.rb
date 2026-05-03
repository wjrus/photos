class CreatePhotoPeopleTags < ActiveRecord::Migration[8.1]
  def change
    create_table :photo_people_tags do |t|
      t.references :photo, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.references :tagged_by, null: false, foreign_key: { to_table: :users }

      t.timestamps
    end

    add_index :photo_people_tags, [ :photo_id, :user_id ], unique: true
  end
end
