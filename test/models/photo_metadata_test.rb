require "test_helper"

class PhotoMetadataTest < ActiveSupport::TestCase
  test "knows when it has a location" do
    metadata = PhotoMetadata.new(latitude: 44.7, longitude: -85.6)

    assert_predicate metadata, :location?
  end
end
