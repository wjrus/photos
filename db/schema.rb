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

ActiveRecord::Schema[8.1].define(version: 2026_10_04_160000) do
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

  create_table "album_access_links", force: :cascade do |t|
    t.bigint "access_count", default: 0, null: false
    t.datetime "created_at", null: false
    t.bigint "created_by_id", null: false
    t.datetime "expires_at"
    t.string "label", default: "Share link", null: false
    t.datetime "last_accessed_at"
    t.bigint "photo_album_id", null: false
    t.datetime "revoked_at"
    t.datetime "updated_at", null: false
    t.index ["created_by_id"], name: "index_album_access_links_on_created_by_id"
    t.index ["photo_album_id", "created_at"], name: "index_album_access_links_on_photo_album_id_and_created_at"
    t.index ["photo_album_id"], name: "index_album_access_links_on_photo_album_id"
    t.index ["revoked_at"], name: "index_album_access_links_on_revoked_at"
  end

  create_table "album_downloads", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "error"
    t.string "filename", null: false
    t.bigint "photo_album_id", null: false
    t.integer "processed_entries", default: 0, null: false
    t.string "status", default: "pending", null: false
    t.integer "total_entries", default: 0, null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.string "zip_path"
    t.index ["photo_album_id"], name: "index_album_downloads_on_photo_album_id"
    t.index ["status"], name: "index_album_downloads_on_status"
    t.index ["user_id", "created_at"], name: "index_album_downloads_on_user_id_and_created_at"
    t.index ["user_id"], name: "index_album_downloads_on_user_id"
  end

  create_table "app_settings", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "key", null: false
    t.datetime "updated_at", null: false
    t.text "value"
    t.index ["key"], name: "index_app_settings_on_key", unique: true
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

  create_table "file_health_checks", force: :cascade do |t|
    t.bigint "active_storage_blob_id", null: false
    t.bigint "actual_byte_size"
    t.string "actual_checksum_md5"
    t.string "actual_checksum_sha256"
    t.string "blob_key", null: false
    t.datetime "checked_at", null: false
    t.datetime "created_at", null: false
    t.text "error"
    t.bigint "expected_byte_size"
    t.string "expected_checksum_md5"
    t.string "expected_checksum_sha256"
    t.datetime "healed_at"
    t.bigint "photo_id", null: false
    t.string "status", null: false
    t.datetime "updated_at", null: false
    t.index ["active_storage_blob_id"], name: "index_file_health_checks_on_active_storage_blob_id"
    t.index ["blob_key"], name: "index_file_health_checks_on_blob_key"
    t.index ["checked_at"], name: "index_file_health_checks_on_checked_at"
    t.index ["photo_id", "checked_at"], name: "index_file_health_checks_on_photo_id_and_checked_at"
    t.index ["photo_id"], name: "index_file_health_checks_on_photo_id"
    t.index ["status"], name: "index_file_health_checks_on_status"
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
    t.index ["created_at"], name: "index_photo_album_memberships_on_created_at"
    t.index ["photo_album_id"], name: "index_photo_album_memberships_on_photo_album_id"
    t.index ["photo_id", "photo_album_id"], name: "index_photo_album_memberships_on_photo_id_and_photo_album_id", unique: true
    t.index ["photo_id"], name: "index_photo_album_memberships_on_photo_id"
  end

  create_table "photo_album_shares", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "photo_album_id", null: false
    t.bigint "shared_by_id", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["photo_album_id", "user_id"], name: "index_photo_album_shares_on_photo_album_id_and_user_id", unique: true
    t.index ["photo_album_id"], name: "index_photo_album_shares_on_photo_album_id"
    t.index ["shared_by_id"], name: "index_photo_album_shares_on_shared_by_id"
    t.index ["user_id"], name: "index_photo_album_shares_on_user_id"
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
    t.index ["updated_at"], name: "index_photo_albums_on_updated_at"
    t.index ["visibility"], name: "index_photo_albums_on_visibility"
  end

  create_table "photo_analysis_objects", force: :cascade do |t|
    t.decimal "confidence", precision: 6, scale: 5
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.bigint "photo_analysis_run_id", null: false
    t.bigint "photo_id", null: false
    t.string "provider", null: false
    t.jsonb "raw", default: {}, null: false
    t.datetime "updated_at", null: false
    t.decimal "x_max", precision: 8, scale: 5
    t.decimal "x_min", precision: 8, scale: 5
    t.decimal "y_max", precision: 8, scale: 5
    t.decimal "y_min", precision: 8, scale: 5
    t.index ["name", "confidence"], name: "index_photo_analysis_objects_on_name_and_confidence"
    t.index ["photo_analysis_run_id"], name: "index_photo_analysis_objects_on_photo_analysis_run_id"
    t.index ["photo_id", "provider", "name"], name: "index_photo_analysis_objects_on_photo_id_and_provider_and_name"
    t.index ["photo_id"], name: "index_photo_analysis_objects_on_photo_id"
  end

  create_table "photo_analysis_runs", force: :cascade do |t|
    t.decimal "cost_usd", precision: 12, scale: 6
    t.datetime "created_at", null: false
    t.text "error"
    t.datetime "finished_at"
    t.bigint "input_tokens"
    t.string "model", null: false
    t.string "model_version"
    t.bigint "output_tokens"
    t.bigint "photo_id", null: false
    t.string "provider", null: false
    t.jsonb "raw", default: {}, null: false
    t.string "request_id"
    t.string "source_checksum_sha256"
    t.string "source_variant", default: "display", null: false
    t.datetime "started_at"
    t.string "status", default: "pending", null: false
    t.text "summary"
    t.datetime "updated_at", null: false
    t.index ["created_at"], name: "index_photo_analysis_runs_on_created_at"
    t.index ["photo_id", "provider", "model", "model_version"], name: "index_photo_analysis_runs_on_photo_provider_model"
    t.index ["photo_id"], name: "index_photo_analysis_runs_on_photo_id"
    t.index ["provider", "status"], name: "index_photo_analysis_runs_on_provider_and_status"
    t.index ["request_id"], name: "index_photo_analysis_runs_on_request_id", unique: true, where: "(request_id IS NOT NULL)"
  end

  create_table "photo_analysis_tags", force: :cascade do |t|
    t.string "category"
    t.decimal "confidence", precision: 6, scale: 5
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.bigint "photo_analysis_run_id", null: false
    t.bigint "photo_id", null: false
    t.string "provider", null: false
    t.jsonb "raw", default: {}, null: false
    t.datetime "updated_at", null: false
    t.index ["category"], name: "index_photo_analysis_tags_on_category"
    t.index ["name", "confidence"], name: "index_photo_analysis_tags_on_name_and_confidence"
    t.index ["photo_analysis_run_id"], name: "index_photo_analysis_tags_on_photo_analysis_run_id"
    t.index ["photo_id", "provider", "name"], name: "index_photo_analysis_tags_on_photo_id_and_provider_and_name", unique: true
    t.index ["photo_id"], name: "index_photo_analysis_tags_on_photo_id"
  end

  create_table "photo_book_exports", force: :cascade do |t|
    t.bigint "photo_book_id", null: false
    t.string "status", default: "pending", null: false
    t.jsonb "snapshot", null: false
    t.string "design_digest", null: false
    t.string "filename", null: false
    t.string "error"
    t.integer "processed_pages", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["photo_book_id"], name: "index_photo_book_exports_on_photo_book_id"
    t.check_constraint "status::text = ANY (ARRAY['pending'::character varying, 'processing'::character varying, 'ready'::character varying, 'failed'::character varying]::text[])", name: "photo_book_exports_status"
  end

  create_table "photo_book_memberships", force: :cascade do |t|
    t.bigint "photo_book_id", null: false
    t.bigint "photo_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["photo_book_id", "photo_id"], name: "index_photo_book_memberships_on_photo_book_id_and_photo_id", unique: true
    t.index ["photo_book_id"], name: "index_photo_book_memberships_on_photo_book_id"
    t.index ["photo_id"], name: "index_photo_book_memberships_on_photo_id"
  end

  create_table "photo_book_pages", force: :cascade do |t|
    t.bigint "photo_book_id", null: false
    t.integer "position", null: false
    t.string "layout", default: "blank", null: false
    t.bigint "primary_photo_id"
    t.bigint "secondary_photo_id"
    t.text "caption", default: "", null: false
    t.text "secondary_caption", default: "", null: false
    t.boolean "show_captions", default: true, null: false
    t.string "image_fit", default: "fill", null: false
    t.integer "primary_focus_x", default: 50, null: false
    t.integer "primary_focus_y", default: 50, null: false
    t.integer "secondary_focus_x", default: 50, null: false
    t.integer "secondary_focus_y", default: 50, null: false
    t.integer "lock_version", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["photo_book_id", "position"], name: "index_photo_book_pages_on_photo_book_id_and_position", unique: true
    t.index ["photo_book_id"], name: "index_photo_book_pages_on_photo_book_id"
    t.index ["primary_photo_id"], name: "index_photo_book_pages_on_primary_photo_id"
    t.index ["secondary_photo_id"], name: "index_photo_book_pages_on_secondary_photo_id"
    t.check_constraint "\"position\" >= 0", name: "photo_book_pages_position"
    t.check_constraint "image_fit::text = ANY (ARRAY['fill'::character varying, 'fit'::character varying]::text[])", name: "photo_book_pages_image_fit"
    t.check_constraint "layout::text = ANY (ARRAY['blank'::character varying, 'full'::character varying, 'fit'::character varying, 'caption'::character varying, 'two_horizontal'::character varying, 'two_vertical'::character varying, 'text'::character varying, 'spread'::character varying]::text[])", name: "photo_book_pages_layout"
    t.check_constraint "primary_focus_x >= 0 AND primary_focus_x <= 100", name: "photo_book_pages_primary_focus_x"
    t.check_constraint "primary_focus_y >= 0 AND primary_focus_y <= 100", name: "photo_book_pages_primary_focus_y"
    t.check_constraint "secondary_focus_x >= 0 AND secondary_focus_x <= 100", name: "photo_book_pages_secondary_focus_x"
    t.check_constraint "secondary_focus_y >= 0 AND secondary_focus_y <= 100", name: "photo_book_pages_secondary_focus_y"
  end

  create_table "photo_books", force: :cascade do |t|
    t.bigint "owner_id", null: false
    t.string "title", null: false
    t.string "format", default: "square_210", null: false
    t.string "cover_layout", default: "fit", null: false
    t.string "cover_title", default: "", null: false
    t.string "cover_subtitle", default: "", null: false
    t.text "back_text", default: "", null: false
    t.string "spine_text", default: "", null: false
    t.jsonb "back_style", default: {}, null: false
    t.jsonb "cover_style", default: {}, null: false
    t.string "background_color", default: "#ffffff", null: false
    t.string "text_color", default: "#18181b", null: false
    t.bigint "cover_photo_id"
    t.bigint "back_photo_id"
    t.integer "lock_version", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["back_photo_id"], name: "index_photo_books_on_back_photo_id"
    t.index ["cover_photo_id"], name: "index_photo_books_on_cover_photo_id"
    t.index ["owner_id"], name: "index_photo_books_on_owner_id"
    t.check_constraint "jsonb_typeof(back_style) = 'object'::text", name: "photo_books_back_style_object"
    t.check_constraint "jsonb_typeof(cover_style) = 'object'::text", name: "photo_books_cover_style_object"
    t.check_constraint "cover_layout::text = ANY (ARRAY['full'::character varying, 'fit'::character varying]::text[])", name: "photo_books_cover_layout"
    t.check_constraint "format::text = ANY (ARRAY['square_210'::character varying, 'square_297'::character varying, 'landscape_a4'::character varying]::text[])", name: "photo_books_format"
  end

  create_table "photo_embeddings", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "dimensions", null: false
    t.datetime "embedded_at", null: false
    t.string "index_key", null: false
    t.string "model", null: false
    t.string "model_version"
    t.bigint "photo_analysis_run_id"
    t.bigint "photo_id", null: false
    t.string "provider", null: false
    t.jsonb "raw", default: {}, null: false
    t.string "source_checksum_sha256"
    t.string "source_variant", default: "display", null: false
    t.datetime "updated_at", null: false
    t.index ["index_key"], name: "index_photo_embeddings_on_index_key", unique: true
    t.index ["photo_analysis_run_id"], name: "index_photo_embeddings_on_photo_analysis_run_id"
    t.index ["photo_id", "provider", "model", "model_version"], name: "index_photo_embeddings_on_photo_provider_model", unique: true
    t.index ["photo_id"], name: "index_photo_embeddings_on_photo_id"
    t.index ["provider", "model"], name: "index_photo_embeddings_on_provider_and_model"
  end

  create_table "photo_location_bounds", force: :cascade do |t|
    t.datetime "calculated_at", null: false
    t.datetime "created_at", null: false
    t.decimal "east", precision: 10, scale: 6, null: false
    t.string "location_id", null: false
    t.decimal "north", precision: 10, scale: 6, null: false
    t.integer "photo_count", default: 0, null: false
    t.decimal "south", precision: 10, scale: 6, null: false
    t.datetime "updated_at", null: false
    t.decimal "west", precision: 10, scale: 6, null: false
    t.index ["calculated_at"], name: "index_photo_location_bounds_on_calculated_at"
    t.index ["location_id"], name: "index_photo_location_bounds_on_location_id", unique: true
  end

  create_table "photo_location_covers", force: :cascade do |t|
    t.bigint "cover_photo_id", null: false
    t.datetime "created_at", null: false
    t.string "location_id", null: false
    t.bigint "owner_id", null: false
    t.datetime "updated_at", null: false
    t.index ["cover_photo_id"], name: "index_photo_location_covers_on_cover_photo_id"
    t.index ["owner_id", "location_id"], name: "index_photo_location_covers_on_owner_id_and_location_id", unique: true
    t.index ["owner_id"], name: "index_photo_location_covers_on_owner_id"
  end

  create_table "photo_location_places", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "geocoded_at"
    t.decimal "latitude", precision: 10, scale: 6
    t.string "location_id", null: false
    t.decimal "longitude", precision: 10, scale: 6
    t.string "name", null: false
    t.jsonb "names", default: [], null: false
    t.jsonb "raw", default: {}, null: false
    t.datetime "updated_at", null: false
    t.index ["location_id"], name: "index_photo_location_places_on_location_id", unique: true
    t.index ["names"], name: "index_photo_location_places_on_names", using: :gin
  end

  create_table "photo_metadata", force: :cascade do |t|
    t.string "aperture"
    t.string "audio_codec"
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
    t.string "location_source"
    t.decimal "longitude", precision: 10, scale: 6
    t.bigint "photo_id", null: false
    t.bigint "photo_place_id"
    t.jsonb "raw", default: {}, null: false
    t.datetime "updated_at", null: false
    t.bigint "video_bitrate"
    t.string "video_codec"
    t.string "video_container"
    t.decimal "video_duration", precision: 12, scale: 3
    t.decimal "video_frame_rate", precision: 10, scale: 3
    t.string "video_profile"
    t.integer "width"
    t.index ["extraction_status"], name: "index_photo_metadata_on_extraction_status"
    t.index ["latitude", "longitude"], name: "index_photo_metadata_on_location", where: "((latitude IS NOT NULL) AND (longitude IS NOT NULL))"
    t.index ["photo_id"], name: "index_photo_metadata_on_photo_id", unique: true
    t.index ["photo_place_id"], name: "index_photo_metadata_on_photo_place_id"
    t.check_constraint "location_source::text = ANY (ARRAY['automatic'::character varying, 'manual'::character varying]::text[])", name: "photo_metadata_location_source"
  end

  create_table "photo_people_tags", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "photo_id", null: false
    t.bigint "tagged_by_id", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["photo_id", "user_id"], name: "index_photo_people_tags_on_photo_id_and_user_id", unique: true
    t.index ["photo_id"], name: "index_photo_people_tags_on_photo_id"
    t.index ["tagged_by_id"], name: "index_photo_people_tags_on_tagged_by_id"
    t.index ["user_id"], name: "index_photo_people_tags_on_user_id"
  end

  create_table "photo_places", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "geocoded_at"
    t.string "identity_key", null: false
    t.decimal "latitude", precision: 10, scale: 6
    t.decimal "longitude", precision: 10, scale: 6
    t.string "map_region_key"
    t.string "map_region_name"
    t.string "name", null: false
    t.jsonb "names", default: [], null: false
    t.string "place_type"
    t.string "provider"
    t.string "provider_place_id"
    t.jsonb "raw", default: {}, null: false
    t.datetime "updated_at", null: false
    t.index ["identity_key"], name: "index_photo_places_on_identity_key", unique: true
    t.index ["names"], name: "index_photo_places_on_names", using: :gin
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
    t.bigint "upload_batch_id"
    t.string "visibility", default: "private", null: false
    t.index "(\nCASE\n    WHEN (captured_at IS NULL) THEN 0\n    ELSE 1\nEND) DESC, COALESCE(captured_at, '0001-01-01 00:00:00'::timestamp without time zone) DESC, created_at DESC, id DESC", name: "index_photos_on_public_stream_cursor", where: "(((visibility)::text = 'public'::text) AND (restricted = false) AND (archived_at IS NULL))"
    t.index "(\nCASE\n    WHEN (captured_at IS NULL) THEN 0\n    ELSE 1\nEND) DESC, COALESCE(captured_at, '0001-01-01 00:00:00'::timestamp without time zone) DESC, created_at DESC, id DESC", name: "index_photos_on_visible_stream_cursor", where: "((restricted = false) AND (archived_at IS NULL))"
    t.index ["archived_at"], name: "index_photos_on_archived_at"
    t.index ["captured_at", "created_at", "id"], name: "index_photos_on_public_stream_order", order: :desc, where: "(((visibility)::text = 'public'::text) AND (restricted = false) AND (archived_at IS NULL))"
    t.index ["captured_at", "created_at", "id"], name: "index_photos_on_visible_stream_order", order: :desc, where: "((restricted = false) AND (archived_at IS NULL))"
    t.index ["captured_at"], name: "index_photos_on_captured_at"
    t.index ["checksum_status"], name: "index_photos_on_checksum_status"
    t.index ["owner_id", "checksum_sha256"], name: "index_photos_on_owner_and_checksum", where: "(checksum_sha256 IS NOT NULL)"
    t.index ["owner_id"], name: "index_photos_on_owner_id"
    t.index ["published_at"], name: "index_photos_on_published_at"
    t.index ["restricted"], name: "index_photos_on_restricted"
    t.index ["updated_at"], name: "index_photos_on_updated_at"
    t.index ["upload_batch_id"], name: "index_photos_on_upload_batch_id"
    t.index ["visibility"], name: "index_photos_on_visibility"
  end

  create_table "repository_events", force: :cascade do |t|
    t.string "category", null: false
    t.datetime "created_at", null: false
    t.jsonb "data", default: {}, null: false
    t.string "event_type", null: false
    t.string "message", null: false
    t.datetime "occurred_at", null: false
    t.datetime "read_at"
    t.string "severity", null: false
    t.bigint "subject_id"
    t.string "subject_type"
    t.datetime "updated_at", null: false
    t.index ["category", "event_type", "occurred_at"], name: "index_repository_events_on_category_type_occurred_at"
    t.index ["read_at", "occurred_at"], name: "index_repository_events_on_read_at_and_occurred_at"
    t.index ["severity", "occurred_at"], name: "index_repository_events_on_severity_and_occurred_at"
    t.index ["subject_type", "subject_id"], name: "index_repository_events_on_subject"
  end

  create_table "upload_batches", force: :cascade do |t|
    t.datetime "committed_at"
    t.datetime "created_at", null: false
    t.bigint "owner_id", null: false
    t.datetime "rolled_back_at"
    t.string "status", default: "reviewing", null: false
    t.datetime "updated_at", null: false
    t.index ["owner_id", "status"], name: "index_upload_batches_on_owner_id_and_status"
    t.index ["owner_id"], name: "index_upload_batches_on_owner_id"
  end

  create_table "users", force: :cascade do |t|
    t.string "avatar_url"
    t.datetime "created_at", null: false
    t.string "email", null: false
    t.text "google_access_token"
    t.text "google_refresh_token"
    t.datetime "google_token_expires_at"
    t.datetime "invite_accepted_at"
    t.datetime "invited_at"
    t.bigint "invited_by_id"
    t.datetime "last_accessed_at"
    t.datetime "last_signed_in_at"
    t.string "name"
    t.string "password_digest"
    t.datetime "password_reset_sent_at"
    t.string "password_reset_token_digest"
    t.string "provider", null: false
    t.string "remember_token_digest"
    t.string "role", default: "viewer", null: false
    t.boolean "show_stream_metadata", default: false, null: false
    t.string "stream_tile_size", default: "medium", null: false
    t.string "uid", null: false
    t.datetime "updated_at", null: false
    t.index ["email"], name: "index_users_on_email", unique: true
    t.index ["invited_by_id"], name: "index_users_on_invited_by_id"
    t.index ["last_accessed_at"], name: "index_users_on_last_accessed_at"
    t.index ["password_reset_token_digest"], name: "index_users_on_password_reset_token_digest", unique: true
    t.index ["provider", "uid"], name: "index_users_on_provider_and_uid", unique: true
    t.index ["remember_token_digest"], name: "index_users_on_remember_token_digest"
  end

  add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
  add_foreign_key "active_storage_variant_records", "active_storage_blobs", column: "blob_id"
  add_foreign_key "album_access_links", "photo_albums"
  add_foreign_key "album_access_links", "users", column: "created_by_id"
  add_foreign_key "album_downloads", "photo_albums"
  add_foreign_key "album_downloads", "users"
  add_foreign_key "drive_archive_objects", "photos"
  add_foreign_key "file_health_checks", "active_storage_blobs"
  add_foreign_key "file_health_checks", "photos"
  add_foreign_key "google_takeout_import_runs", "users", column: "owner_id"
  add_foreign_key "google_takeout_imports", "photos", on_delete: :nullify
  add_foreign_key "photo_album_memberships", "photo_albums"
  add_foreign_key "photo_album_memberships", "photos"
  add_foreign_key "photo_album_shares", "photo_albums"
  add_foreign_key "photo_album_shares", "users"
  add_foreign_key "photo_album_shares", "users", column: "shared_by_id"
  add_foreign_key "photo_albums", "photos", column: "cover_photo_id"
  add_foreign_key "photo_albums", "users", column: "owner_id"
  add_foreign_key "photo_analysis_objects", "photo_analysis_runs"
  add_foreign_key "photo_analysis_objects", "photos"
  add_foreign_key "photo_analysis_runs", "photos"
  add_foreign_key "photo_analysis_tags", "photo_analysis_runs"
  add_foreign_key "photo_analysis_tags", "photos"
  add_foreign_key "photo_book_exports", "photo_books"
  add_foreign_key "photo_book_memberships", "photo_books"
  add_foreign_key "photo_book_memberships", "photos"
  add_foreign_key "photo_book_pages", "photo_books"
  add_foreign_key "photo_book_pages", "photos", column: "primary_photo_id", on_delete: :nullify
  add_foreign_key "photo_book_pages", "photos", column: "secondary_photo_id", on_delete: :nullify
  add_foreign_key "photo_books", "photos", column: "back_photo_id", on_delete: :nullify
  add_foreign_key "photo_books", "photos", column: "cover_photo_id", on_delete: :nullify
  add_foreign_key "photo_books", "users", column: "owner_id"
  add_foreign_key "photo_embeddings", "photo_analysis_runs"
  add_foreign_key "photo_embeddings", "photos"
  add_foreign_key "photo_location_covers", "photos", column: "cover_photo_id"
  add_foreign_key "photo_location_covers", "users", column: "owner_id"
  add_foreign_key "photo_metadata", "photo_places"
  add_foreign_key "photo_metadata", "photos"
  add_foreign_key "photo_people_tags", "photos"
  add_foreign_key "photo_people_tags", "users"
  add_foreign_key "photo_people_tags", "users", column: "tagged_by_id"
  add_foreign_key "photos", "upload_batches"
  add_foreign_key "photos", "users", column: "owner_id"
  add_foreign_key "upload_batches", "users", column: "owner_id"
  add_foreign_key "users", "users", column: "invited_by_id"
end
