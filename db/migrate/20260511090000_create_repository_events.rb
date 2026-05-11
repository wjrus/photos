class CreateRepositoryEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :repository_events do |t|
      t.string :category, null: false
      t.string :event_type, null: false
      t.string :severity, null: false
      t.string :message, null: false
      t.references :subject, polymorphic: true, null: true, index: true
      t.jsonb :data, null: false, default: {}
      t.datetime :occurred_at, null: false
      t.datetime :read_at

      t.timestamps
    end

    add_index :repository_events, [ :read_at, :occurred_at ]
    add_index :repository_events, [ :severity, :occurred_at ]
    add_index :repository_events, [ :category, :event_type, :occurred_at ], name: "index_repository_events_on_category_type_occurred_at"
  end
end
