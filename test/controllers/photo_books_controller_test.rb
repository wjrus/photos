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
    assert_equal 18, book.pages.count
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
    assert_equal 18, users(:one).photo_books.find_by!(title: "Bulk book").pages.count
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

  test "export checks warnings, queues one snapshot and protects downloads" do
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
