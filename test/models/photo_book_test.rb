require "test_helper"
require_relative "../support/photo_book_test_helper"

class PhotoBookTest < ActiveSupport::TestCase
  include PhotoBookTestHelper

  test "new books start with four inside pages and assigning photos is idempotent" do
    book, photo = book_with_photo
    assert_equal 4, book.pages.count
    assert_equal 0, book.add_photos!([ photo ])
    assert_equal 1, book.photos.count
    assert_equal 6, PhotoBookLayout.new(book.design_snapshot).pages.size
  end

  test "assignment excludes another owner, videos, private and archived photos" do
    book, photo = book_with_photo
    restricted = book_photo(title: "Restricted")
    restricted.update!(restricted: true)
    archived = book_photo(title: "Archived")
    archived.update!(archived_at: Time.current)
    other = book_photo(owner: users(:two))
    video = users(:one).photos.create!(title: "Synthetic video") do |record|
      record.original.attach(io: StringIO.new("synthetic-video"), filename: "synthetic.mp4", content_type: "video/mp4")
    end
    assert_equal 0, book.add_photos!([ photo, restricted, archived, other, video ])
    assert_equal [ photo.id ], book.photos.pluck(:id)
    assert_not book.photo_book_memberships.new(photo: other).valid?
  end

  test "page and cover assignments must come from this book" do
    book, = book_with_photo
    other = book_photo(title: "Not assigned")
    page = book.pages.first
    page.primary_photo = other
    assert_not page.valid?
    book.cover_photo = other
    assert_not book.valid?
  end

  test "removing a photo clears placements and covers without deleting the original" do
    book, photo = book_with_photo
    book.update!(cover_photo: photo, back_photo: photo)
    page = book.pages.first
    page.update!(layout: "two_horizontal", secondary_photo: photo)
    book.remove_photo!(photo.id)
    assert_nil book.reload.cover_photo_id
    assert_nil book.back_photo_id
    assert_nil page.reload.primary_photo_id
    assert_nil page.secondary_photo_id
    assert book.photos.empty?
    assert photo.reload.original.attached?
  end

  test "unavailable covers can be repaired individually without blocking other edits" do
    book, photo = book_with_photo
    book.update!(cover_photo: photo, back_photo: photo)
    photo.update!(restricted: true)
    book.update!(cover_photo: nil, cover_title: "Repairing the cover")
    assert_equal photo.id, book.reload.back_photo_id
    book.cover_photo = photo
    assert_not book.valid?
    book.reload.update!(back_photo: nil)
    assert_nil book.reload.back_photo_id
  end

  test "a new spread gets a right-hand blank page when necessary" do
    book, = book_with_photo
    spread = book.append_page!(layout: "spread")
    layout = PhotoBookLayout.new(book.design_snapshot)
    assert_equal "blank", book.pages.to_a[-2].layout
    assert_equal [ 6, 7 ], layout.pages.select { |page| page[:source_id] == spread.id }.map { |page| page[:number] }
    assert layout.errors.empty?
  end

  test "deleting a source photo leaves a repairable page and prevents export" do
    book, photo = book_with_photo
    photo.destroy!
    assert_nil book.pages.first.reload.primary_photo_id
    assert_includes PhotoBookPreflight.new(book).errors.join, "needs a photo"
  end

  test "print dimensions follow EXIF orientation without loading the raw metadata" do
    book, photo = book_with_photo
    photo.metadata.update!(raw: { "Orientation" => "6" })
    source = book.design_snapshot.fetch("photos").first
    assert_equal 1600, source.fetch("width")
    assert_equal 2400, source.fetch("height")
    assert_not photo.reload.print_metadata.has_attribute?(:raw)
  end

  test "supported still images remain eligible when their MIME type is generic" do
    book, photo = book_with_photo
    photo.update_columns(content_type: "application/octet-stream")
    assert book.eligible_photos.exists?(photo.id)
  end

  test "cover typography is bounded and changes the saved design digest" do
    book, = book_with_photo
    digest = book.design_digest
    book.update!(cover_style: { font: "garamond_italic", color: "#fff5e1", size: "42", shadow: "1", shadow_color: "#242424", alignment: "right", position: "top" })
    assert_not_equal digest, book.design_digest
    assert_equal "garamond_italic", book.design_snapshot.fetch("cover_style").fetch("font")
    [ { font: "../../untrusted.ttf" }, { color: "red; background: url(example.org)" }, { size: "900" },
      { alignment: "untrusted" }, { position: "outside" }, { shadow: "perhaps" }, { shadow_color: "#fff" }, [] ].each do |style|
      book.cover_style = style
      assert_not book.valid?, style.inspect
    end
    book.cover_style = {}
    book.back_style = { font: "unknown" }
    assert_not book.valid?
  end
end
