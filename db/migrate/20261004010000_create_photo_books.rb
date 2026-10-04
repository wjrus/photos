class CreatePhotoBooks < ActiveRecord::Migration[8.1]
  def change
    create_table :photo_books do |t|
      t.references :owner, null: false, foreign_key: { to_table: :users }
      t.string :title, null: false
      t.string :format, null: false, default: "square_210"
      t.string :cover_layout, null: false, default: "fit"
      t.string :cover_title, null: false, default: ""
      t.string :cover_subtitle, null: false, default: ""
      t.text :back_text, null: false, default: ""
      t.string :spine_text, null: false, default: ""
      t.string :background_color, null: false, default: "#ffffff"
      t.string :text_color, null: false, default: "#18181b"
      t.references :cover_photo, foreign_key: { to_table: :photos, on_delete: :nullify }
      t.references :back_photo, foreign_key: { to_table: :photos, on_delete: :nullify }
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end
    add_check_constraint :photo_books, "format IN ('square_210', 'square_297', 'landscape_a4')", name: "photo_books_format"
    add_check_constraint :photo_books, "cover_layout IN ('full', 'fit')", name: "photo_books_cover_layout"

    create_table :photo_book_memberships do |t|
      t.references :photo_book, null: false, foreign_key: true
      t.references :photo, null: false, foreign_key: true
      t.timestamps
    end
    add_index :photo_book_memberships, [ :photo_book_id, :photo_id ], unique: true

    create_table :photo_book_pages do |t|
      t.references :photo_book, null: false, foreign_key: true
      t.integer :position, null: false
      t.string :layout, null: false, default: "blank"
      t.references :primary_photo, foreign_key: { to_table: :photos, on_delete: :nullify }
      t.references :secondary_photo, foreign_key: { to_table: :photos, on_delete: :nullify }
      t.text :caption, null: false, default: ""
      t.text :secondary_caption, null: false, default: ""
      t.string :image_fit, null: false, default: "fill"
      t.integer :primary_focus_x, null: false, default: 50
      t.integer :primary_focus_y, null: false, default: 50
      t.integer :secondary_focus_x, null: false, default: 50
      t.integer :secondary_focus_y, null: false, default: 50
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end
    add_index :photo_book_pages, [ :photo_book_id, :position ], unique: true
    add_check_constraint :photo_book_pages, "position >= 0", name: "photo_book_pages_position"
    add_check_constraint :photo_book_pages, "layout IN ('blank', 'full', 'fit', 'caption', 'two_horizontal', 'two_vertical', 'text', 'spread')", name: "photo_book_pages_layout"
    add_check_constraint :photo_book_pages, "image_fit IN ('fill', 'fit')", name: "photo_book_pages_image_fit"
    %w[primary_focus_x primary_focus_y secondary_focus_x secondary_focus_y].each do |column|
      add_check_constraint :photo_book_pages, "#{column} BETWEEN 0 AND 100", name: "photo_book_pages_#{column}"
    end

    create_table :photo_book_exports do |t|
      t.references :photo_book, null: false, foreign_key: true
      t.string :status, null: false, default: "pending"
      t.jsonb :snapshot, null: false
      t.string :design_digest, null: false
      t.string :filename, null: false
      t.string :error
      t.integer :processed_pages, null: false, default: 0
      t.timestamps
    end
    add_check_constraint :photo_book_exports, "status IN ('pending', 'processing', 'ready', 'failed')", name: "photo_book_exports_status"
  end
end
