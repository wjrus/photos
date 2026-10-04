class PhotoBookMembershipsController < ApplicationController
  owner_access_message "Only the owner can manage photobooks."
  before_action :require_owner!

  def create
    if params[:photo_id].present?
      photo = current_user.photos.where(restricted: false, archived_at: nil).find(params[:photo_id])
      if params[:new_photo_book_title].blank? && params[:photo_book_id].blank?
        return redirect_to safe_return_path(default: photo_path(photo)), alert: "Choose a photobook or name a new one."
      end
      book = if params[:new_photo_book_title].present?
        current_user.photo_books.create!(title: params[:new_photo_book_title], cover_title: params[:new_photo_book_title])
      else
        current_user.photo_books.find(params[:photo_book_id])
      end
      added = book.add_photos!([ photo ])
      redirect_to safe_return_path(default: photo_path(photo)), notice: added.positive? ? "Added to #{book.title}." : "Only available still photos can be added, and each photo only needs to be added once."
    else
      book = current_user.photo_books.find(params[:photo_book_id])
      album = current_user.photo_albums.find(params[:album_id])
      added = 0
      album.photos.where(owner_id: current_user.id, restricted: false, archived_at: nil).find_in_batches do |photos|
        added += book.add_photos!(photos)
      end
      redirect_to photo_book_path(book, tab: "photos"), notice: "Added #{added} #{'photo'.pluralize(added)} from #{album.title}."
    end
  rescue ActiveRecord::RecordInvalid => error
    redirect_to safe_return_path, alert: error.record.errors.full_messages.to_sentence
  end

  def destroy
    book = current_user.photo_books.find(params[:photo_book_id])
    book.remove_photo!(params[:id])
    redirect_to photo_book_path(book, tab: "photos"), notice: "Photo removed from the book and its page placements. It remains in your library."
  end
end
