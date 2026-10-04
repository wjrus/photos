module Api
  module V1
    class PhotoBooksController < BaseController
      before_action :require_owner!

      def index
        books = current_user.photo_books.order(id: :desc)
        books = books.where("id < ?", Integer(params[:before_id])) if params[:before_id].present?
        rows = books.limit(page_limit + 1).to_a
        render json: { photo_books: rows.first(page_limit).map { |book| payload(book) }, has_more: rows.size > page_limit,
          next_before_id: rows.first(page_limit).last&.id }
      end

      def create
        title = params.require(:title)
        book = current_user.photo_books.create!(title: title, cover_title: title)
        render json: { photo_book: payload(book) }, status: :created
      end

      private

      def payload(book)
        { id: book.id, title: book.title, updated_at: book.updated_at }
      end
    end
  end
end
