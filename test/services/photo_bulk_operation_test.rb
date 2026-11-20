require "test_helper"
require "active_record/testing/query_assertions"

class PhotoBulkOperationTest < ActiveSupport::TestCase
  include ActiveRecord::Assertions::QueryAssertions

  setup do
    @owner = users(:one)
    blob = ActiveStorage::Blob.create_and_upload!(
      io: File.open(Rails.root.join("public/icon.png")), filename: "bulk.png", content_type: "image/png"
    )
    @photos = 10.times.map { |index| @owner.photos.create!(title: "Bulk #{index}", original: blob) }
  end

  test "publishing reads photos and validation attachments in a bounded batch" do
    queries = []
    subscriber = ->(event) {
      queries << event.payload[:sql] if !event.payload[:cached] && event.payload[:name] != "SCHEMA" && event.payload[:sql].start_with?("SELECT")
    }
    result = nil
    ActiveRecord::Base.uncached do
      ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") { result = operation("publish").call }
    end

    assert_equal 10, result[:affected_count]
    assert_equal 10, Photo.where(id: @photos.map(&:id), visibility: "public").count
    assert_equal 4, queries.size, queries.join("\n")
    assert_equal 1, queries.count { |query| query.include?("FOR UPDATE") }
  end

  test "a fresh locked copy preserves current fields rather than stale caller values" do
    Photo.where(id: @photos.first.id).update_all(title: "Updated elsewhere")

    operation("publish").call

    assert_equal "Updated elsewhere", @photos.first.reload.title
    assert_predicate @photos.first, :public?
  end

  test "valid sidecars are preloaded without skipping validation" do
    sidecar = ActiveStorage::Blob.create_and_upload!(io: StringIO.new("synthetic"), filename: "adjustments.aae", content_type: "application/xml")
    @photos.each { |photo| ActiveStorage::Attachment.create!(record: photo, name: "sidecars", blob: sidecar) }

    assert_queries_match(/FROM "active_storage_attachments"/, count: 2) { operation("publish").call }

    assert_equal 10, Photo.where(id: @photos.map(&:id), visibility: "public").count
  end

  test "batch locking retains the submitted order when adding photos to a book" do
    book = @owner.photo_books.create!(title: "Selection order")
    @photos.reverse!

    operation("add_to_photo_book", attributes: { photo_book_id: book.id }).call

    assert_equal @photos.map(&:id), book.photo_book_memberships.order(:id).pluck(:photo_id)
  end

  test "a photo removed since selection aborts the whole operation" do
    stale = @photos.last
    stale.destroy!

    assert_raises(ActiveRecord::RecordNotFound) { operation("publish").call }
    assert_equal 0, Photo.where(id: @photos.map(&:id), visibility: "public").count
  end

  test "ownership is checked again on the locked records" do
    Photo.where(id: @photos.last.id).update_all(owner_id: users(:two).id)

    assert_raises(PhotoBulkOperation::InvalidAction) { operation("publish").call }
    assert_equal 0, Photo.where(id: @photos.map(&:id), visibility: "public").count
  end

  test "validations still reject an invalid sidecar and roll back earlier changes" do
    invalid = ActiveStorage::Blob.create_and_upload!(io: StringIO.new("synthetic"), filename: "invalid.txt", content_type: "text/plain")
    ActiveStorage::Attachment.create!(record: @photos.last, name: "sidecars", blob: invalid)

    assert_raises(ActiveRecord::RecordInvalid) { operation("publish").call }
    assert_equal 0, Photo.where(id: @photos.map(&:id), visibility: "public").count
  end

  private

  def operation(action, attributes: {})
    PhotoBulkOperation.new(owner: @owner, photos: @photos, action: action, attributes: attributes)
  end
end
