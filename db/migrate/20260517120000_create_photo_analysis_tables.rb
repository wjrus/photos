class CreatePhotoAnalysisTables < ActiveRecord::Migration[8.1]
  def change
    create_table :photo_analysis_runs do |t|
      t.references :photo, null: false, foreign_key: true
      t.string :provider, null: false
      t.string :model, null: false
      t.string :model_version
      t.string :status, null: false, default: "pending"
      t.string :source_variant, null: false, default: "display"
      t.string :source_checksum_sha256
      t.datetime :started_at
      t.datetime :finished_at
      t.text :summary
      t.text :error
      t.jsonb :raw, null: false, default: {}
      t.timestamps

      t.index [ :photo_id, :provider, :model, :model_version ], name: "index_photo_analysis_runs_on_photo_provider_model"
      t.index [ :provider, :status ]
      t.index :created_at
    end

    create_table :photo_analysis_tags do |t|
      t.references :photo, null: false, foreign_key: true
      t.references :photo_analysis_run, null: false, foreign_key: true
      t.string :provider, null: false
      t.string :name, null: false
      t.string :category
      t.decimal :confidence, precision: 6, scale: 5
      t.jsonb :raw, null: false, default: {}
      t.timestamps

      t.index [ :photo_id, :provider, :name ], unique: true
      t.index [ :name, :confidence ]
      t.index :category
    end

    create_table :photo_analysis_objects do |t|
      t.references :photo, null: false, foreign_key: true
      t.references :photo_analysis_run, null: false, foreign_key: true
      t.string :provider, null: false
      t.string :name, null: false
      t.decimal :confidence, precision: 6, scale: 5
      t.decimal :x_min, precision: 8, scale: 5
      t.decimal :y_min, precision: 8, scale: 5
      t.decimal :x_max, precision: 8, scale: 5
      t.decimal :y_max, precision: 8, scale: 5
      t.jsonb :raw, null: false, default: {}
      t.timestamps

      t.index [ :photo_id, :provider, :name ]
      t.index [ :name, :confidence ]
    end

    create_table :photo_embeddings do |t|
      t.references :photo, null: false, foreign_key: true
      t.references :photo_analysis_run, foreign_key: true
      t.string :provider, null: false
      t.string :model, null: false
      t.string :model_version
      t.integer :dimensions, null: false
      t.string :source_variant, null: false, default: "display"
      t.string :source_checksum_sha256
      t.string :index_key, null: false
      t.datetime :embedded_at, null: false
      t.jsonb :raw, null: false, default: {}
      t.timestamps

      t.index [ :photo_id, :provider, :model, :model_version ], unique: true, name: "index_photo_embeddings_on_photo_provider_model"
      t.index [ :provider, :model ]
      t.index :index_key, unique: true
    end
  end
end
