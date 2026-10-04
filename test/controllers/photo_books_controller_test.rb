require "test_helper"
require_relative "../support/photo_book_test_helper"

class PhotoBooksControllerTest < ActionDispatch::IntegrationTest
  include PhotoBookTestHelper

  setup do
    @book, @photo = book_with_photo
    sign_in_book_owner
  end

  test "owner can browse create and edit a photobook" do
    get photo_books_path
    assert_response :success
    assert_select "h1", "Photobooks"
    assert_difference "PhotoBook.count", 1 do
      post photo_books_path, params: { photo_book: { title: "New story", format: "landscape_a4" } }
    end
    book = users(:one).photo_books.order(:id).last
    assert_equal 4, book.pages.count
    assert_redirected_to photo_book_path(book)
    get photo_book_path(@book, page_id: @book.pages.first.id)
    assert_response :success
    assert_select "svg.photobook-artwork", 1
    assert_select ".photobook-unprinted-page", 1
    assert_select "input[value='Save page']"
    assert_equal "private, no-store", response.headers["Cache-Control"]
    patch photo_book_path(@book), params: { photo_book: { cover_title: "Updated cover", cover_photo_id: @photo.id, lock_version: @book.lock_version } }
    assert_redirected_to photo_book_path(@book, page_id: "front")
    assert_equal "Updated cover", @book.reload.cover_title
  end

  test "anonymous users and viewers cannot read mutate or export books" do
    delete sign_out_path
    get photo_books_path
    assert_redirected_to root_path
    sign_in_book_owner(users(:two))
    get photo_book_path(@book)
    assert_redirected_to root_path
    assert_no_difference "PhotoBookExport.count" do
      post photo_book_exports_path(@book)
    end
    assert_redirected_to root_path
    patch photo_book_page_path(@book, @book.pages.first), params: { photo_book_page: { caption: "Unauthorized" } }
    assert_redirected_to root_path
    assert_equal "Beside the lake.", @book.pages.first.caption
  end

  test "another owner's book and page cannot be reached" do
    other = users(:two).photo_books.create!(title: "Other owner")
    get photo_book_path(other)
    assert_response :not_found
    patch photo_book_page_path(@book, other.pages.first), params: { photo_book_page: { caption: "Wrong book" } }
    assert_response :not_found
  end

  test "bulk assignment adds eligible photos and can create a book" do
    assert_difference "PhotoBookMembership.count", 1 do
      post photo_bulk_actions_path, params: { bulk_action: "add_to_photo_book", photo_ids: [ @photo.id ], new_photo_book_title: "Bulk book" }
    end
    assert_equal 4, users(:one).photo_books.find_by!(title: "Bulk book").pages.count
    assert_no_difference "PhotoBookMembership.count" do
      post photo_bulk_actions_path, params: { bulk_action: "add_to_photo_book", photo_ids: [ @photo.id ], photo_book_id: @book.id }
    end
  end

  test "album assignment and a single photo assignment preserve library photos" do
    album = users(:one).photo_albums.create!(title: "Synthetic album", source: "manual")
    second = book_photo(title: "Another scene")
    album.photos << second
    post photo_book_memberships_path(@book), params: { album_id: album.id }
    assert_redirected_to photo_book_path(@book, tab: "photos")
    assert @book.photos.exists?(second.id)
    post photo_photo_book_memberships_path(second), params: { new_photo_book_title: "Single book" }
    assert users(:one).photo_books.find_by!(title: "Single book").photos.exists?(second.id)
    delete photo_book_membership_path(@book, second.id)
    assert_not @book.photos.exists?(second.id)
    assert Photo.exists?(second.id)
  end

  test "live preview does not save changes and rejects unassigned photos" do
    page = @book.pages.first
    post preview_photo_book_path(@book), params: { page_id: page.id, preview_key: "#{page.id}-0", photo_book_page: { caption: "Preview only" } }, headers: { "Accept" => "text/vnd.turbo-stream.html" }
    assert_response :success
    assert_includes response.body, "Preview only"
    assert_equal "Beside the lake.", page.reload.caption
    other = book_photo(title: "Not in book")
    post preview_photo_book_path(@book), params: { page_id: page.id, photo_book_page: { primary_photo_id: other.id } }
    assert_response :unprocessable_entity
    assert_equal @photo.id, page.reload.primary_photo_id
  end

  test "page editing detects stale forms and reordering persists" do
    page = @book.pages.first
    version = page.lock_version
    page.update!(caption: "Changed in another tab")
    patch photo_book_page_path(@book, page), params: { photo_book_page: { caption: "Stale change", lock_version: version } }
    assert_equal "Changed in another tab", page.reload.caption
    assert_match(/another tab/, flash[:alert])
    patch move_photo_book_page_path(@book, page), params: { direction: "down" }
    assert_equal page.id, @book.pages.reload.to_a[1].id
  end

  test "tray tracks visible placements across pages and covers and supports reuse" do
    second = book_photo(title: "Unused scene")
    @book.add_photos!([ second ])
    get tray_photo_book_path(@book)
    assert_response :success
    assert_select "button[data-photo-id='#{@photo.id}']", 0
    assert_select "button[data-photo-id='#{second.id}']", 1
    get tray_photo_book_path(@book), params: { show_used: "1" }
    assert_select "button[data-photo-id='#{@photo.id}'] .photobook-tray-used", "Used in book"
    @book.update!(back_photo: second)
    @book.pages.first.update!(layout: "text")
    get tray_photo_book_path(@book)
    assert_select "button[data-photo-id='#{@photo.id}']", 1
    assert_select "button[data-photo-id='#{second.id}']", 0
    @book.pages.first.update!(layout: "two_vertical", secondary_photo: second)
    get tray_photo_book_path(@book)
    assert_select "button[data-photo-id]", 0
  end

  test "tray uses unsaved page and cover placements without mutating the design" do
    second = book_photo(title: "Replacement scene")
    @book.add_photos!([ second ])
    page = @book.pages.first
    get tray_photo_book_path(@book), params: { page_id: page.id, photo_book_page: { primary_photo_id: second.id } }, headers: { "Accept" => "text/vnd.turbo-stream.html" }
    assert_response :success
    assert_select "turbo-stream[action='replace'][target='photobook-tray']"
    assert_select "button[data-photo-id='#{@photo.id}']", 1
    assert_select "button[data-photo-id='#{second.id}']", 0
    assert_equal @photo.id, page.reload.primary_photo_id
    assert_equal "private, no-store", response.headers["Cache-Control"]
    get tray_photo_book_path(@book), params: { preview_key: "back", photo_book: { back_photo_id: second.id } }
    assert_select "button[data-photo-id='#{second.id}']", 0
    assert_nil @book.reload.back_photo_id
    post preview_photo_book_path(@book), params: { preview_key: "back", photo_book: { back_photo_id: second.id, back_text: "Draft cover" } }
    assert_response :success
    assert_includes response.body, "Draft cover"
    assert_nil @book.reload.back_photo_id
    patch photo_book_path(@book), params: { preview_key: "back", photo_book: { back_photo_id: second.id, lock_version: @book.lock_version } }
    assert_redirected_to photo_book_path(@book, page_id: "back")
    assert_equal second.id, @book.reload.back_photo_id
  end

  test "tray search pagination and authorization stay scoped to eligible book photos" do
    25.times do |index|
      photo = users(:one).photos.create!(title: "Tray scene #{index}") { |record| record.original.attach(@photo.original.blob) }
      @book.add_photos!([ photo ])
    end
    @photo.update!(restricted: true)
    get tray_photo_book_path(@book), params: { show_used: "1", tray_search: "Tray scene" }
    assert_select "button[data-photo-id]", 24
    assert_select "a", "More photos"
    get tray_photo_book_path(@book), params: { show_used: "1", tray_search: "Tray scene", tray_page: 2 }
    assert_select "button[data-photo-id]", 1
    get tray_photo_book_path(@book), params: { show_used: "1", tray_search: "%" }
    assert_select "button[data-photo-id]", 0
    get tray_photo_book_path(@book), params: { show_used: "1", tray_search: @photo.title }
    assert_select "button[data-photo-id]", 0
    other = book_photo(title: "Not assigned")
    get tray_photo_book_path(@book), params: { page_id: @book.pages.first.id, photo_book_page: { primary_photo_id: other.id } }
    assert_response :unprocessable_entity
    other_book = users(:two).photo_books.create!(title: "Other book")
    get tray_photo_book_path(other_book)
    assert_response :not_found
    get tray_photo_book_path(@book), params: { page_id: other_book.pages.first.id }
    assert_response :not_found
  end

  test "export checks warnings, queues one snapshot and protects downloads" do
    14.times { @book.append_page! }
    assert_no_difference "PhotoBookExport.count" do
      post photo_book_exports_path(@book)
    end
    assert_difference "PhotoBookExport.count", 1 do
      assert_enqueued_with(job: PreparePhotoBookExportJob) do
        post photo_book_exports_path(@book), params: { allow_low_resolution: "1" }
      end
    end
    assert_no_difference "PhotoBookExport.count" do
      post photo_book_exports_path(@book), params: { allow_low_resolution: "1" }
    end
    export = @book.exports.first
    PreparePhotoBookExportJob.perform_now(export)
    get file_photo_book_export_path(@book, export)
    assert_response :success
    assert_equal "application/pdf", response.media_type
    assert response.body.start_with?("%PDF-")
    assert_equal "private, no-store", response.headers["Cache-Control"]
    @photo.update!(restricted: true)
    get file_photo_book_export_path(@book, export)
    assert_redirected_to photo_book_path(@book)
  end
end
