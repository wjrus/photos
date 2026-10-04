class CreateMobileApiTables < ActiveRecord::Migration[8.1]
  def change
    create_table :device_sessions do |t|
      t.references :user, null: false, foreign_key: true
      t.string :name, null: false
      t.string :platform, null: false
      t.string :token_digest, null: false
      t.string :refresh_token_digest, null: false
      t.string :authentication_fingerprint, null: false
      t.datetime :expires_at, null: false
      t.datetime :refresh_expires_at, null: false
      t.datetime :last_used_at
      t.datetime :revoked_at
      t.datetime :restricted_unlocked_until
      t.string :restricted_password_digest
      t.timestamps
    end
    add_index :device_sessions, :token_digest, unique: true
    add_index :device_sessions, :refresh_token_digest, unique: true

    create_table :mobile_uploads do |t|
      t.references :device_session, null: false, foreign_key: true
      t.references :photo, foreign_key: { on_delete: :nullify }
      t.string :client_asset_id, null: false
      t.string :filename, null: false
      t.string :content_type, null: false
      t.bigint :byte_size, null: false
      t.string :checksum_sha256, null: false
      t.datetime :captured_at
      t.datetime :expires_at, null: false
      t.datetime :completed_at
      t.boolean :duplicate, default: false, null: false
      t.timestamps
    end
    add_index :mobile_uploads, [ :device_session_id, :client_asset_id ], unique: true
    add_index :mobile_uploads, :expires_at
    add_check_constraint :mobile_uploads, "byte_size > 0 AND byte_size <= 8589934592", name: "mobile_uploads_byte_size"

    create_table :mobile_upload_chunks do |t|
      t.references :mobile_upload, null: false, foreign_key: true
      t.integer :position, null: false
      t.timestamps
    end
    add_index :mobile_upload_chunks, [ :mobile_upload_id, :position ], unique: true
    add_check_constraint :mobile_upload_chunks, "position >= 0 AND position < 1024", name: "mobile_upload_chunks_position"
  end
end
