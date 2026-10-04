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
    assert_select ".photobook-unprinted-page", 0
    assert_select ".photobook-page-position", "Page 1 · Right page"
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

  test "tray removal returns only versions and stays scoped to the owner's book and page" do
    page = @book.pages.first
    @book.update!(cover_photo: @photo, back_photo: @photo)
    old_book = @book.lock_version
    old_page = page.lock_version
    delete photo_book_membership_path(@book, @photo.id), params: { page_id: page.id }, headers: { "Accept" => "application/json" }
    assert_response :success
    data = response.parsed_body
    assert_equal({ "before" => old_book, "after" => @book.reload.lock_version }, data.fetch("book"))
    assert_equal({ "before" => old_page, "after" => page.reload.lock_version }, data.fetch("page"))
    assert_equal "private, no-store", response.headers["Cache-Control"]
    assert_nil page.primary_photo_id
    assert_nil @book.cover_photo_id
    assert_nil @book.back_photo_id
    assert @photo.reload.original.attached?
    @book.add_photos!([ @photo ])
    other = users(:two).photo_books.create!(title: "Other book")
    delete photo_book_membership_path(@book, @photo.id), params: { page_id: other.pages.first.id }, headers: { "Accept" => "application/json" }
    assert_response :not_found
    assert @book.photos.exists?(@photo.id)
    delete photo_book_membership_path(other, @photo.id), headers: { "Accept" => "application/json" }
    assert_response :not_found
    unassigned = book_photo(title: "Unassigned")
    assert_no_difference "PhotoBookMembership.count" do
      delete photo_book_membership_path(@book, unassigned.id), headers: { "Accept" => "application/json" }
    end
    assert_response :not_found
    assert Photo.exists?(unassigned.id)
    sign_in_book_owner(users(:two))
    assert_no_difference "PhotoBookMembership.count" do
      delete photo_book_membership_path(@book, @photo.id), headers: { "Accept" => "application/json" }
    end
    assert_response :forbidden
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

  test "single-page previews include every printed page and preserve the selected spread half" do
    second = @book.pages.to_a[1]
    second.update!(layout: "spread", primary_photo: @photo)
    get photo_book_path(@book, page_id: "#{second.id}-1")
    assert_response :success
    assert_select "#photobook-preview svg", 1
    assert_select "#photobook-preview svg[viewBox='210.0 0 210.0 210.0']", 1
    assert_select ".photobook-page-position", "Page 3 · Right page"
    assert_select ".photobook-page-link.is-active", "Page 3"
    assert_select "input[name='preview_key'][value='#{second.id}-1']"
    post preview_photo_book_path(@book), params: { page_id: second.id, preview_key: "#{second.id}-1", view: "page", photo_book_page: { primary_focus_x: 10 } }
    assert_response :success
    assert_select "#photobook-preview svg[viewBox='210.0 0 210.0 210.0']", 1
    assert_equal 50, second.reload.primary_focus_x
    post preview_photo_book_path(@book), params: { page_id: second.id, preview_key: "#{second.id}-1", view: "spread" }
    assert_select "#photobook-preview svg", 2
    assert_select "button[data-preview-view='spread'][aria-pressed='true']"
    patch photo_book_page_path(@book, second), params: { preview_key: "#{second.id}-1", view: "spread", photo_book_page: { primary_focus_x: 10, lock_version: second.lock_version } }
    assert_redirected_to photo_book_path(@book, page_id: "#{second.id}-1", view: "spread")
    get photo_book_path(@book, page_id: "#{second.id}-999", view: "unsupported")
    assert_select ".photobook-page-position", "Page 2 · Left page"
    assert_select "#photobook-preview svg", 1
    get photo_book_path(@book, page_id: @book.pages.first.id, view: "spread")
    assert_select ".photobook-unprinted-page", 1
  end

  test "page removal uses an in-app confirmation with a CSRF protected delete form" do
    page = @book.pages.first
    get photo_book_path(@book, page_id: page.id)
    assert_select "[data-turbo-confirm]", 0
    assert_select "[role='dialog'][aria-labelledby='remove-book-page-#{page.id}-title']" do
      assert_select "button[data-action='confirm-modal#close']", "Cancel"
      assert_select "button[type='submit']", "Remove page"
    end
    assert_select "form#remove-book-page-#{page.id}-form[action='#{photo_book_page_path(@book, page)}'][method='post']" do
      assert_select "input[name='_method'][value='delete']"
    end
    assert_select "[role='dialog'][aria-labelledby='leave-book-page-title']"
  end

  test "cover typography previews without saving and persists independently on each cover" do
    style = { font: "garamond_italic", size: "42", color: "#fff5e1", shadow: "1", shadow_color: "#112233", alignment: "right", position: "top" }
    post preview_photo_book_path(@book), params: { preview_key: "front", photo_book: { cover_layout: "full", cover_style: style } }, headers: { "Accept" => "text/vnd.turbo-stream.html" }
    assert_response :success
    assert_select "text[data-font='garamond_italic'][fill='#fff5e1']"
    assert_select "text.photobook-text-shadow[fill='#112233']"
    assert_empty @book.reload.cover_style
    patch photo_book_path(@book), params: { photo_book: { cover_style: style, lock_version: @book.lock_version } }
    assert_equal "garamond_italic", @book.reload.cover_style.fetch("font")
    assert_empty @book.back_style
    post preview_photo_book_path(@book), params: { photo_book: { cover_style: { font: "untrusted.ttf" } } }
    assert_response :unprocessable_entity
    assert_equal "garamond_italic", @book.reload.cover_style.fetch("font")
  end

  test "caption visibility previews then saves without deleting caption text" do
    source = @book.pages.first
    post preview_photo_book_path(@book), params: { page_id: source.id, photo_book_page: { show_captions: "0" } }, headers: { "Accept" => "text/vnd.turbo-stream.html" }
    assert_response :success
    assert_select "svg text", 0
    assert source.reload.show_captions?
    patch photo_book_page_path(@book, source), params: { photo_book_page: { show_captions: "0", lock_version: source.lock_version } }
    assert_not source.reload.show_captions?
    assert_equal "Beside the lake.", source.caption
  end

  test "cover positioning previews without saving and persists independently" do
    @book.update!(cover_photo: @photo, back_photo: @photo, cover_layout: "full")
    post preview_photo_book_path(@book), params: { preview_key: "front", photo_book: { cover_focus_x: "0", cover_focus_y: "25" } }, headers: { "Accept" => "text/vnd.turbo-stream.html" }
    assert_response :success
    assert_select "svg image[x='0.0'][y='0.0']", 1
    assert_equal 50, @book.reload.cover_focus_x
    patch photo_book_path(@book), params: { photo_book: { cover_focus_x: "0", cover_focus_y: "25", lock_version: @book.lock_version } }
    assert_redirected_to photo_book_path(@book, page_id: "front")
    assert_equal [ 0, 25, 50, 50 ], @book.reload.attributes.values_at(*PhotoBook::COVER_POSITION_ATTRIBUTES)
    patch photo_book_path(@book), params: { preview_key: "back", photo_book: { back_focus_x: "100", back_focus_y: "75", lock_version: @book.lock_version } }
    assert_equal [ 0, 25, 100, 75 ], @book.reload.attributes.values_at(*PhotoBook::COVER_POSITION_ATTRIBUTES)
    get photo_book_path(@book, page_id: "back")
    assert_select "#photobook-preview image[x='-105.0']", 1
    post preview_photo_book_path(@book), params: { photo_book: { cover_focus_x: "101" } }
    assert_response :unprocessable_entity
    patch photo_book_path(@book), params: { photo_book: { back_focus_y: "-1", lock_version: @book.lock_version } }
    assert_response :unprocessable_entity
    assert_equal 75, @book.reload.back_focus_y
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
