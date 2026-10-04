class AddPhotoBookTypography < ActiveRecord::Migration[8.1]
  def change
    add_column :photo_books, :cover_style, :jsonb, null: false, default: {}
    add_column :photo_books, :back_style, :jsonb, null: false, default: {}
    add_column :photo_book_pages, :show_captions, :boolean, null: false, default: true
    %w[cover_style back_style].each do |column|
      add_check_constraint :photo_books, "jsonb_typeof(#{column}) = 'object'", name: "photo_books_#{column}_object"
    end
  end
end
