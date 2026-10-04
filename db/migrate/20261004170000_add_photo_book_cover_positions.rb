class AddPhotoBookCoverPositions < ActiveRecord::Migration[8.1]
  def change
    %w[cover_focus_x cover_focus_y back_focus_x back_focus_y].each do |column|
      add_column :photo_books, column, :integer, null: false, default: 50
      add_check_constraint :photo_books, "#{column} BETWEEN 0 AND 100", name: "photo_books_#{column}"
    end
  end
end
