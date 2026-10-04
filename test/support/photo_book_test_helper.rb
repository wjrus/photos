require "vips"

module PhotoBookTestHelper
  def book_photo(title: "Synthetic landscape", owner: users(:one), width: 2400, height: 1600, color: [ 30, 110, 160 ])
    bytes = Vips::Image.black(width, height, bands: 3).new_from_image(color).pngsave_buffer
    photo = owner.photos.create!(title: title) do |record|
      record.original.attach(io: StringIO.new(bytes), filename: "synthetic-landscape.png", content_type: "image/png")
    end
    photo.create_metadata!(width: width, height: height)
    photo
  end

  def book_with_photo
    book = users(:one).photo_books.create!(title: "Synthetic journeys", cover_title: "Synthetic journeys")
    photo = book_photo
    book.add_photos!([ photo ])
    book.pages.first.update!(layout: "caption", primary_photo: photo, caption: "Beside the lake.")
    [ book.reload, photo ]
  end

  def sign_in_book_owner(user = users(:one))
    user.update!(password: "synthetic-password12")
    post password_sign_in_path, params: { email: user.email, password: "synthetic-password12" }
  end

  def pending_book_export(book, allow_low_resolution: true)
    snapshot = book.design_snapshot
    digest = Digest::SHA256.hexdigest(snapshot.to_json)
    snapshot["allow_low_resolution"] = allow_low_resolution
    book.exports.create!(snapshot: snapshot, design_digest: digest, filename: "synthetic-book.pdf")
  end
end
