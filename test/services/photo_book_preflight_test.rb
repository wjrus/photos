require "test_helper"
require_relative "../support/photo_book_test_helper"

class PhotoBookPreflightTest < ActiveSupport::TestCase
  include PhotoBookTestHelper

  test "four-page designs stay small while print checks enforce the printer minimum" do
    book, = book_with_photo
    assert_includes PhotoBookPreflight.new(book).errors.join, "20–122"
    assert_equal 4, book.pages.count
    assert_equal 6, PhotoBookLayout.new(book.design_snapshot).pages.size
  end

  test "caption layout is printable and low resolution is reported" do
    book, = book_with_photo(print_ready: true)
    preflight = PhotoBookPreflight.new(book)
    assert preflight.ready?, preflight.errors.join
    assert preflight.warnings.any? { |warning| warning.include?("DPI") }
    first = preflight.layout.pages[1]
    assert_equal "right", first[:side]
    assert_equal [ nil, first ], preflight.layout.facing_pages(first.fetch(:key))
  end

  test "page count and spread alignment are checked independently" do
    book, photo = book_with_photo(print_ready: true)
    book.pages.first.update!(layout: "spread", primary_photo: photo)
    errors = PhotoBookPreflight.new(book).errors.join
    assert_includes errors, "left-hand"
    assert_includes errors, "even page count"
    book.pages.where.not(id: book.pages.first.id).destroy_all
    assert_includes PhotoBookPreflight.new(book).errors.join, "20–122"
  end

  test "text overflow and unsupported glyphs are blocked" do
    book, = book_with_photo(print_ready: true)
    book.pages.first.update!(caption: "Long caption " * 120)
    assert_includes PhotoBookPreflight.new(book).errors.join, "does not fit"
    book.pages.first.update!(caption: "Emoji 🚀")
    assert_includes PhotoBookPreflight.new(book).errors.join, "cannot display"
  end

  test "private and archived sources cannot be exported" do
    book, photo = book_with_photo(print_ready: true)
    photo.update!(restricted: true)
    assert_not PhotoBookPreflight.new(book).ready?
    photo.update!(restricted: false, archived_at: Time.current)
    assert_not PhotoBookPreflight.new(book).ready?
  end

  test "two-photo layouts include both captions and use safe margins" do
    book, photo = book_with_photo(print_ready: true)
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

  test "cover text overlays use selected fonts colors placement and alignment without panels" do
    book, photo = book_with_photo(print_ready: true)
    book.update!(cover_photo: photo, cover_layout: "full", cover_subtitle: "Summer · Été",
      cover_style: { font: "garamond_italic", size: 42, color: "#fff5e1", shadow: true, shadow_color: "#112233", alignment: "right", position: "top" },
      back_text: "The end", back_style: { font: "lato", size: 20, color: "#223344", shadow: false, alignment: "left", position: "bottom" })
    layout = PhotoBookLayout.new(book.design_snapshot)
    assert_empty layout.errors
    cover = layout.pages.first
    assert_empty cover.fetch(:panels)
    assert_equal 210, cover.fetch(:images).first.fetch(:width)
    title = cover.fetch(:texts).first
    assert_equal "garamond_italic", title.fetch(:font)
    assert_equal "#fff5e1", title.fetch(:color)
    assert_equal "#112233", title.fetch(:shadow_color)
    assert_equal 15, title.fetch(:y)
    assert_operator title.fetch(:line_x).first, :>, 15
    back = layout.pages.last.fetch(:texts).first
    assert_equal "lato", back.fetch(:font)
    assert_nil back.fetch(:shadow_color)
    assert_equal [ 15 ], back.fetch(:line_x)
    assert_operator back.fetch(:y), :>, 150
  end

  test "all bundled fonts measure print text and full-cover defaults contrast without a panel" do
    book, = book_with_photo
    book.update!(cover_layout: "full", cover_title: "Summer · Été")
    PhotoBookTypography::FONTS.each_key do |font|
      book.update!(cover_style: { font: font })
      layout = PhotoBookLayout.new(book.design_snapshot)
      assert_empty layout.errors, font
      title = layout.pages.first.fetch(:texts).first
      assert_equal font, title.fetch(:font)
      assert_equal "#ffffff", title.fetch(:color)
      assert_equal "#000000", title.fetch(:shadow_color)
    end
  end

  test "hidden photo captions preserve text and reclaim space in every caption layout" do
    book, photo = book_with_photo(print_ready: true)
    %w[caption two_horizontal two_vertical].each do |kind|
      source = book.pages.first.reload
      source.update!(layout: kind, secondary_photo: photo, show_captions: true)
      original = PhotoBookLayout.new(book.design_snapshot).pages[1]
      source.update!(show_captions: false, caption: "Hidden text 🚀", secondary_caption: "Still saved")
      layout = PhotoBookLayout.new(book.design_snapshot)
      assert_empty layout.errors
      page = layout.pages[1]
      assert_empty page.fetch(:texts)
      assert_operator page.fetch(:images).first.fetch(:height), :>, original.fetch(:images).first.fetch(:height)
      assert_equal "Hidden text 🚀", source.reload.caption
      source.update!(caption: "Visible text")
    end
    book.pages.first.reload.update!(layout: "text", caption: "Keep page text", show_captions: false)
    assert_equal [ "Keep page text" ], PhotoBookLayout.new(book.design_snapshot).pages[1].fetch(:texts).first.fetch(:lines)
  end

  test "version-one export snapshots retain their original cover design" do
    book, = book_with_photo
    snapshot = book.design_snapshot.merge("version" => 1)
    snapshot.delete("cover_style")
    snapshot.delete("back_style")
    snapshot.fetch("pages").each { |page| page.delete("show_captions") }
    cover = PhotoBookLayout.new(snapshot).pages.first
    assert_equal 1, cover.fetch(:panels).size
    assert_equal "sans", cover.fetch(:texts).first.fetch(:font)
    assert_equal 24, cover.fetch(:texts).first.fetch(:size)
  end

  test "cover crops stay filled at either edge and fit artwork stays centered" do
    book, photo = book_with_photo
    portrait = book_photo(width: 1600, height: 2400)
    book.add_photos!([ portrait ])
    book.update!(cover_photo: photo, back_photo: portrait, cover_layout: "full", cover_focus_x: 0, back_focus_y: 100)
    layout = PhotoBookLayout.new(book.design_snapshot)
    assert_equal({ x: 0.0, y: 0.0, width: 315.0, height: 210.0 }, layout.image_box(layout.pages.first.fetch(:images).first, width: 2400, height: 1600))
    assert_equal({ x: 0.0, y: -105.0, width: 210.0, height: 315.0 }, layout.image_box(layout.pages.last.fetch(:images).first, width: 1600, height: 2400))
    book.update!(cover_focus_x: 100, back_focus_y: 0)
    layout = PhotoBookLayout.new(book.design_snapshot)
    assert_equal(-105.0, layout.image_box(layout.pages.first.fetch(:images).first, width: 2400, height: 1600).fetch(:x))
    assert_equal 0.0, layout.image_box(layout.pages.last.fetch(:images).first, width: 1600, height: 2400).fetch(:y)
    old_snapshot = book.design_snapshot.except(*PhotoBook::COVER_POSITION_ATTRIBUTES)
    old_layout = PhotoBookLayout.new(old_snapshot)
    assert_equal(-52.5, old_layout.image_box(old_layout.pages.first.fetch(:images).first, width: 2400, height: 1600).fetch(:x))
    book.update!(cover_layout: "fit")
    fit_layout = PhotoBookLayout.new(book.design_snapshot)
    assert_equal [ 50, 50 ], fit_layout.pages.first.fetch(:images).first.values_at(:focus_x, :focus_y)
    assert_equal [ 50, 50 ], fit_layout.pages.last.fetch(:images).first.values_at(:focus_x, :focus_y)
  end
end
