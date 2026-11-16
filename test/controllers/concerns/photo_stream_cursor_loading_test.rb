require "test_helper"
require "active_record/testing/query_assertions"

class PhotoStreamCursorLoadingTest < ActiveSupport::TestCase
  include ActiveRecord::Assertions::QueryAssertions

  setup do
    @controller = HomeController.new
    @owner = users(:one)
    blob = ActiveStorage::Blob.create_and_upload!(
      io: File.open(Rails.root.join("public/icon.png")), filename: "cursor.png", content_type: "image/png"
    )
    @photos = 3.times.map do |index|
      photo = @owner.photos.create!(title: "Cursor #{index}", original: blob, visibility: "public", captured_at: index.days.ago)
      photo.create_metadata!(extraction_status: "complete", raw: {})
      photo
    end
    @photos.first.original.variant(:stream).processed
    @scope = Photo.visible_to(nil).with_original_variant_records.stream_order
  end

  test "finding a focused photo reads only the cursor without loading its media" do
    @controller.params = ActionController::Parameters.new(photo_id: @photos.second.id)

    photo = assert_queries_count(1) { @controller.send(:focused_stream_photo, @scope) }

    assert_equal @photos.second.stream_cursor, photo.stream_cursor
    assert_not photo.association(:original_attachment).loaded?
    assert_not photo.association(:display_metadata).loaded?
  end

  %i[stream chronological].each do |order|
    test "#{order} focus preloads metadata only for the rendered page" do
      method = order == :stream ? :paginate_photo_stream_focused : :paginate_chronological_photo_stream_focused
      page = nil
      assert_queries_match(/FROM "photo_metadata"/, count: 1) do
        page, = @controller.send(method, @scope, @photos.second)
      end

      expected = order == :stream ? [ @photos.second, @photos.last ] : [ @photos.second, @photos.first ]
      assert_equal expected.map(&:id), page.map(&:id)
      assert page.all? { |photo| photo.association(:display_metadata).loaded? }
      assert page.all? { |photo| photo.association(:original_attachment).loaded? }
    end
  end

  test "cursor lookups still exclude inaccessible photos" do
    @photos.second.update!(visibility: "private")
    @controller.params = ActionController::Parameters.new(photo_id: @photos.second.id)

    assert_nil @controller.send(:focused_stream_photo, @scope)
  end
end
