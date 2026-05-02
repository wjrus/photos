# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_05_02_213000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "active_storage_attachments", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.bigint "record_id", null: false
    t.string "record_type", null: false
    t.index ["blob_id"], name: "index_active_storage_attachments_on_blob_id"
    t.index ["record_type", "record_id", "name", "blob_id"], name: "index_active_storage_attachments_uniqueness", unique: true
  end

  create_table "active_storage_blobs", force: :cascade do |t|
    t.bigint "byte_size", null: false
    t.string "checksum"
    t.string "content_type"
    t.datetime "created_at", null: false
    t.string "filename", null: false
    t.string "key", null: false
    t.text "metadata"
    t.string "service_name", null: false
    t.index ["key"], name: "index_active_storage_blobs_on_key", unique: true
  end

  create_table "active_storage_variant_records", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.string "variation_digest", null: false
    t.index ["blob_id", "variation_digest"], name: "index_active_storage_variant_records_uniqueness", unique: true
  end

  create_table "drive_archive_objects", force: :cascade do |t|
    t.datetime "archived_at"
    t.datetime "created_at", null: false
    t.text "error"
    t.string "google_file_id"
    t.string "google_md5_checksum"
    t.bigint "google_size"
    t.bigint "photo_id", null: false
    t.string "status", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.datetime "verified_at"
    t.index ["google_file_id"], name: "index_drive_archive_objects_on_google_file_id"
    t.index ["photo_id"], name: "index_drive_archive_objects_on_photo_id", unique: true
    t.index ["status"], name: "index_drive_archive_objects_on_status"
  end

  create_table "google_takeout_import_runs", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "error"
    t.datetime "finished_at"
    t.bigint "owner_id", null: false
    t.string "path", null: false
    t.datetime "started_at"
    t.string "status", default: "queued", null: false
    t.jsonb "summary", default: {}, null: false
    t.datetime "updated_at", null: false
    t.index ["created_at"], name: "index_google_takeout_import_runs_on_created_at"
    t.index ["owner_id"], name: "index_google_takeout_import_runs_on_owner_id"
    t.index ["status"], name: "index_google_takeout_import_runs_on_status"
  end

  create_table "google_takeout_imports", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "entry_name", null: false
    t.text "error"
    t.datetime "imported_at"
    t.string "original_filename"
    t.bigint "photo_id"
    t.string "sha256"
    t.string "status", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.string "zip_path", null: false
    t.index ["photo_id"], name: "index_google_takeout_imports_on_photo_id"
    t.index ["sha256"], name: "index_google_takeout_imports_on_sha256"
    t.index ["status"], name: "index_google_takeout_imports_on_status"
    t.index ["zip_path", "entry_name"], name: "index_google_takeout_imports_on_zip_path_and_entry_name", unique: true
  end

  create_table "photo_album_memberships", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "photo_album_id", null: false
    t.bigint "photo_id", null: false
    t.datetime "updated_at", null: false
    t.index ["photo_album_id"], name: "index_photo_album_memberships_on_photo_album_id"
    t.index ["photo_id", "photo_album_id"], name: "index_photo_album_memberships_on_photo_id_and_photo_album_id", unique: true
    t.index ["photo_id"], name: "index_photo_album_memberships_on_photo_id"
  end

  create_table "photo_albums", force: :cascade do |t|
    t.bigint "cover_photo_id"
    t.datetime "created_at", null: false
    t.bigint "owner_id", null: false
    t.datetime "published_at"
    t.jsonb "raw", default: {}, null: false
    t.string "source", default: "manual", null: false
    t.string "source_path"
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.string "visibility", default: "private", null: false
    t.index ["cover_photo_id"], name: "index_photo_albums_on_cover_photo_id"
    t.index ["owner_id", "source", "source_path"], name: "index_photo_albums_on_owner_id_and_source_and_source_path", unique: true
    t.index ["owner_id"], name: "index_photo_albums_on_owner_id"
    t.index ["published_at"], name: "index_photo_albums_on_published_at"
    t.index ["visibility"], name: "index_photo_albums_on_visibility"
  end

  create_table "photo_metadata", force: :cascade do |t|
    t.string "aperture"
    t.string "camera_make"
    t.string "camera_model"
    t.datetime "captured_at"
    t.datetime "created_at", null: false
    t.string "exposure_time"
    t.datetime "extracted_at"
    t.text "extraction_error"
    t.string "extraction_status", default: "pending", null: false
    t.string "focal_length"
    t.integer "height"
    t.integer "iso"
    t.decimal "latitude", precision: 10, scale: 6
    t.string "lens_model"
    t.decimal "longitude", precision: 10, scale: 6
    t.bigint "photo_id", null: false
    t.jsonb "raw", default: {}, null: false
    t.datetime "updated_at", null: false
    t.integer "width"
    t.index ["extraction_status"], name: "index_photo_metadata_on_extraction_status"
    t.index ["photo_id"], name: "index_photo_metadata_on_photo_id", unique: true
  end

  create_table "photos", force: :cascade do |t|
    t.datetime "archived_at"
    t.bigint "byte_size"
    t.datetime "captured_at"
    t.datetime "checksum_checked_at"
    t.text "checksum_error"
    t.string "checksum_sha256"
    t.string "checksum_status", default: "pending", null: false
    t.string "content_type"
    t.datetime "created_at", null: false
    t.text "description"
    t.string "original_filename"
    t.bigint "owner_id", null: false
    t.datetime "published_at"
    t.boolean "restricted", default: false, null: false
    t.string "title"
    t.datetime "updated_at", null: false
    t.string "visibility", default: "private", null: false
    t.index ["captured_at"], name: "index_photos_on_captured_at"
    t.index ["checksum_status"], name: "index_photos_on_checksum_status"
    t.index ["owner_id"], name: "index_photos_on_owner_id"
    t.index ["published_at"], name: "index_photos_on_published_at"
    t.index ["restricted"], name: "index_photos_on_restricted"
    t.index ["visibility"], name: "index_photos_on_visibility"
  end

  create_table "users", force: :cascade do |t|
    t.string "avatar_url"
    t.datetime "created_at", null: false
    t.string "email", null: false
    t.text "google_access_token"
    t.text "google_refresh_token"
    t.datetime "google_token_expires_at"
    t.datetime "last_signed_in_at"
    t.string "name"
    t.string "provider", null: false
    t.string "role", default: "viewer", null: false
    t.string "uid", null: false
    t.datetime "updated_at", null: false
    t.index ["email"], name: "index_users_on_email"
    t.index ["provider", "uid"], name: "index_users_on_provider_and_uid", unique: true
  end

  add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
  add_foreign_key "active_storage_variant_records", "active_storage_blobs", column: "blob_id"
  add_foreign_key "drive_archive_objects", "photos"
  add_foreign_key "google_takeout_import_runs", "users", column: "owner_id"
  add_foreign_key "google_takeout_imports", "photos"
  add_foreign_key "photo_album_memberships", "photo_albums"
  add_foreign_key "photo_album_memberships", "photos"
  add_foreign_key "photo_albums", "photos", column: "cover_photo_id"
  add_foreign_key "photo_albums", "users", column: "owner_id"
  add_foreign_key "photo_metadata", "photos"
  add_foreign_key "photos", "users", column: "owner_id"
end
