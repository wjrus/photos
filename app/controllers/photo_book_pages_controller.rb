class PhotoBookPagesController < ApplicationController
  owner_access_message "Only the owner can design photobooks."
  before_action :require_owner!
  before_action :set_book
  before_action :set_page, except: :create

  def create
    layout = params[:layout].to_s.presence || "blank"
    return redirect_to photo_book_path(@book), alert: "Choose a page layout." unless PhotoBookPage::LAYOUTS.key?(layout)

    @book.with_lock do
      added = layout == "spread" ? (@book.pages.sum(&:page_span).even? ? 3 : 2) : 1
      if @book.pages.sum(&:page_span) + added + 2 > PhotoBook::MAX_PRINTED_PAGES
        return redirect_to photo_book_path(@book), alert: "This book has reached the layflat page limit."
      end
      @page = @book.append_page!(layout: layout)
    end
    redirect_to designer_path, notice: "Page added."
  end

  def update
    @book.with_lock do
      @page.update!(page_params)
      @book.touch
    end
    redirect_to designer_path, notice: "Page saved."
  rescue ActiveRecord::RecordInvalid => error
    redirect_to designer_path, alert: error.record.errors.full_messages.to_sentence
  rescue ActiveRecord::StaleObjectError
    redirect_to designer_path, alert: "This page changed in another tab. Reload it before saving."
  end

  def move
    @book.with_lock do
      pages = @book.pages.to_a
      index = pages.index { |page| page.id == @page.id }
      target = params[:direction] == "up" ? index - 1 : index + 1
      if %w[up down].include?(params[:direction]) && target >= 0 && target < pages.size
        neighbor = pages[target]
        position = @page.position
        neighbor_position = neighbor.position
        @page.update!(position: pages.map(&:position).max + 1)
        neighbor.update!(position: position)
        @page.update!(position: neighbor_position)
        @book.touch
      end
    end
    redirect_to designer_path, notice: "Page order saved."
  end

  def destroy
    @book.with_lock do
      @page.destroy!
      @book.touch
    end
    redirect_to photo_book_path(@book), notice: "Page removed."
  end

  private

  def designer_path
    key = @page.layout == "spread" && params[:preview_key] == "#{@page.id}-1" ? params[:preview_key] : @page.id
    photo_book_path(@book, page_id: key, view: params[:view] == "spread" ? "spread" : "page")
  end

  def set_book
    @book = current_user.photo_books.find(params[:photo_book_id])
  end

  def set_page
    @page = @book.pages.find(params[:id])
  end

  def page_params
    params.require(:photo_book_page).permit(*PhotoBookPage::DESIGN_ATTRIBUTES, :lock_version)
  end
end
