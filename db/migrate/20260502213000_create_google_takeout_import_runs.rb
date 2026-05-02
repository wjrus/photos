class CreateGoogleTakeoutImportRuns < ActiveRecord::Migration[8.1]
  def change
    create_table :google_takeout_import_runs do |t|
      t.references :owner, null: false, foreign_key: { to_table: :users }
      t.string :path, null: false
      t.string :status, null: false, default: "queued"
      t.jsonb :summary, null: false, default: {}
      t.text :error
      t.datetime :started_at
      t.datetime :finished_at

      t.timestamps
    end

    add_index :google_takeout_import_runs, :status
    add_index :google_takeout_import_runs, :created_at
  end
end
