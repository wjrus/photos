require "test_helper"
require_relative "../support/photo_book_test_helper"

class PhotoBookPreflightTest < ActiveSupport::TestCase
  include PhotoBookTestHelper

  test "caption layout is printable and low resolution is reported" do
    book, = book_with_photo
    preflight = PhotoBookPreflight.new(book)
    assert preflight.ready?, preflight.errors.join
    assert preflight.warnings.any? { |warning| warning.include?("DPI") }
    first = preflight.layout.pages[1]
    assert_equal "right", first[:side]
    assert_equal [ nil, first ], preflight.layout.facing_pages(first.fetch(:key))
  end

  test "page count and spread alignment are checked independently" do
    book, photo = book_with_photo
    book.pages.first.update!(layout: "spread", primary_photo: photo)
    errors = PhotoBookPreflight.new(book).errors.join
    assert_includes errors, "left-hand"
    assert_includes errors, "even page count"
    book.pages.where.not(id: book.pages.first.id).destroy_all
    assert_includes PhotoBookPreflight.new(book).errors.join, "20–122"
  end

  test "text overflow and unsupported glyphs are blocked" do
    book, = book_with_photo
    book.pages.first.update!(caption: "Long caption " * 120)
    assert_includes PhotoBookPreflight.new(book).errors.join, "does not fit"
    book.pages.first.update!(caption: "Emoji 🚀")
    assert_includes PhotoBookPreflight.new(book).errors.join, "cannot display"
  end

  test "private and archived sources cannot be exported" do
    book, photo = book_with_photo
    photo.update!(restricted: true)
    assert_not PhotoBookPreflight.new(book).ready?
    photo.update!(restricted: false, archived_at: Time.current)
    assert_not PhotoBookPreflight.new(book).ready?
  end

  test "two-photo layouts include both captions and use safe margins" do
    book, photo = book_with_photo
    second = book_photo(title: "Second photo")
    book.add_photos!([ second ])
    %w[two_horizontal two_vertical].each do |kind|
      book.pages.first.update!(layout: kind, primary_photo: photo, secondary_photo: second, caption: "First caption", secondary_caption: "Second caption")
      preflight = PhotoBookPreflight.new(book)
      assert preflight.ready?, preflight.errors.join
      page = preflight.layout.pages[1]
      assert_equal 2, page.fetch(:images).size
      assert_equal [ "First caption", "Second caption" ], page.fetch(:texts).flat_map { |text| text.fetch(:lines) }
      page.fetch(:images).each do |image|
        assert_operator image.fetch(:x), :>=, 10
        assert_operator image.fetch(:y), :>=, 10
      end
    end
  end
end
