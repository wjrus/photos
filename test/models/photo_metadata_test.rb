require "test_helper"

class PhotoMetadataTest < ActiveSupport::TestCase
  test "knows when it has a location" do
    metadata = PhotoMetadata.new(latitude: 44.7, longitude: -85.6)

    assert_predicate metadata, :location?
  end

  test "recovers when another worker creates metadata first" do
    photo = attached_photo
    created_metadata = nil
    original_create = PhotoMetadata.method(:create!)

    PhotoMetadata.define_singleton_method(:create!) do |photo:|
      created_metadata = PhotoMetadata.new(photo: photo)
      created_metadata.save!
      raise ActiveRecord::RecordNotUnique, "duplicate metadata"
    end

    metadata = PhotoMetadata.for_photo(photo)

    assert_equal created_metadata, metadata
  ensure
    PhotoMetadata.define_singleton_method(:create!, original_create)
  end

  private

  def attached_photo
    photo = users(:one).photos.new
    photo.original.attach(
      io: File.open(Rails.root.join("public/icon.png")),
      filename: "fixture.png",
      content_type: "image/png"
    )
    photo.save!
    photo
  end
end
