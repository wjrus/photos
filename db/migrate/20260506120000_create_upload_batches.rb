class CreateUploadBatches < ActiveRecord::Migration[8.1]
  def change
    create_table :upload_batches do |t|
      t.references :owner, null: false, foreign_key: { to_table: :users }
      t.string :status, null: false, default: "reviewing"
      t.datetime :committed_at
      t.datetime :rolled_back_at

      t.timestamps
    end

    add_reference :photos, :upload_batch, foreign_key: true
    add_index :upload_batches, [ :owner_id, :status ]
  end
end
