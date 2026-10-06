class CreatePhotoBookOrders < ActiveRecord::Migration[8.1]
  def change
    create_table :photo_book_orders do |t|
      t.references :photo_book_export, null: false, foreign_key: true
      t.string :environment, null: false
      t.string :reference, null: false
      t.string :remote_id
      t.string :status, null: false, default: "draft"
      t.string :sku, null: false
      t.integer :copies, null: false, default: 1
      t.string :shipping_method, null: false, default: "Budget"
      t.string :currency, null: false, default: "USD"
      t.jsonb :recipient, null: false, default: {}
      t.jsonb :quote, null: false, default: {}
      t.jsonb :product, null: false, default: {}
      t.jsonb :request_payload, null: false, default: {}
      t.jsonb :remote_status, null: false, default: {}
      t.datetime :quoted_at
      t.datetime :approved_at
      t.datetime :asset_expires_at
      t.datetime :remote_updated_at
      t.datetime :refreshed_at
      t.text :error
      t.timestamps
    end
    add_index :photo_book_orders, :reference, unique: true
    add_index :photo_book_orders, [ :environment, :remote_id ], unique: true
    add_check_constraint :photo_book_orders, "copies BETWEEN 1 AND 10", name: "photo_book_orders_copies"
    add_check_constraint :photo_book_orders, "environment IN ('sandbox', 'live')", name: "photo_book_orders_environment"
    add_check_constraint :photo_book_orders, "status IN ('draft', 'quoted', 'submitting', 'submitted')", name: "photo_book_orders_status"
  end
end
