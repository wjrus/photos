require "test_helper"

class PhotoTest < ActiveSupport::TestCase
  test "new photos default to private" do
    photo = users(:one).photos.new

    assert_equal "private", photo.visibility
  end

  test "copies original blob attributes" do
    photo = users(:one).photos.new
    photo.original.attach(
      io: File.open(Rails.root.join("public/icon.png")),
      filename: "summer-road.png",
      content_type: "image/png"
    )

    assert_predicate photo, :valid?
    assert_equal "summer-road.png", photo.original_filename
    assert_equal "image/png", photo.content_type
    assert_equal "Summer road", photo.title
  end

  test "accepts video originals" do
    photo = users(:one).photos.new
    photo.original.attach(
      io: StringIO.new("fake mov bytes"),
      filename: "clip.mov",
      content_type: "video/quicktime"
    )

    assert_predicate photo, :valid?
    assert_predicate photo, :video?
    assert_equal "Clip", photo.title
  end

  test "accepts heic originals" do
    photo = users(:one).photos.new
    photo.original.attach(
      io: StringIO.new("fake heic bytes"),
      filename: "portrait.HEIC",
      content_type: "image/heic"
    )

    assert_predicate photo, :valid?
    assert_predicate photo, :image?
    assert_equal "Portrait", photo.title
  end

  test "preserves aae sidecars with originals" do
    photo = users(:one).photos.new
    photo.original.attach(
      io: File.open(Rails.root.join("public/icon.png")),
      filename: "portrait.png",
      content_type: "image/png"
    )
    photo.sidecars.attach(
      io: StringIO.new("<?xml version=\"1.0\"?>"),
      filename: "portrait.AAE",
      content_type: "application/xml"
    )

    assert_predicate photo, :valid?
    assert_equal 1, photo.sidecar_count
  end

  test "rejects non aae sidecars" do
    photo = users(:one).photos.new
    photo.original.attach(
      io: File.open(Rails.root.join("public/icon.png")),
      filename: "portrait.png",
      content_type: "image/png"
    )
    photo.sidecars.attach(
      io: StringIO.new("not a sidecar"),
      filename: "notes.txt",
      content_type: "text/plain"
    )

    assert_not photo.valid?
    assert_includes photo.errors[:sidecars], "must be Apple .AAE sidecar files"
  end

  test "enqueues checksum job after create" do
    assert_enqueued_with(job: ChecksumOriginalJob) do
      attached_photo
    end
  end

  test "complete checksum photos enqueue drive archive without recomputing checksum" do
    assert_no_enqueued_jobs only: ChecksumOriginalJob do
      assert_enqueued_with(job: MirrorOriginalToDriveJob) do
        attached_photo(checksum_sha256: "abc123", checksum_status: "complete")
      end
    end
  end

  test "stream order uses captured date before import date" do
    older_imported_later = attached_photo(captured_at: 2.years.ago, created_at: 1.minute.ago)
    newer_imported_earlier = attached_photo(captured_at: 1.day.ago, created_at: 1.week.ago)
    unknown_imported_now = attached_photo(created_at: Time.current)

    ordered = Photo.where(id: [ older_imported_later.id, newer_imported_earlier.id, unknown_imported_now.id ]).stream_order

    assert_equal [ newer_imported_earlier, older_imported_later, unknown_imported_now ], ordered.to_a
  end

  test "stream cursor paginates captured dates before unknown dates" do
    newer = attached_photo(captured_at: 1.day.ago, created_at: 1.week.ago)
    older = attached_photo(captured_at: 2.years.ago, created_at: 1.minute.ago)
    unknown = attached_photo(created_at: Time.current)
    scope = Photo.where(id: [ newer.id, older.id, unknown.id ])

    assert_equal [ older, unknown ], scope.before_stream_cursor(newer.stream_cursor).stream_order.to_a
    assert_equal [ unknown ], scope.before_stream_cursor(older.stream_cursor).stream_order.to_a
  end

  test "finds stream neighbors without loading the whole stream" do
    newest = attached_photo(captured_at: 1.hour.ago)
    current = attached_photo(captured_at: 1.day.ago)
    oldest = attached_photo(captured_at: 1.week.ago)
    scope = Photo.where(id: [ newest.id, current.id, oldest.id ])

    assert_equal newest, scope.stream_before(current)
    assert_equal oldest, scope.stream_after(current)
  end

  test "enqueues metadata extraction job after create" do
    assert_enqueued_with(job: ExtractPhotoMetadataJob) do
      attached_photo
    end
  end

  test "enqueues image derivative job after create" do
    assert_enqueued_with(job: GeneratePhotoDerivativesJob) do
      attached_photo
    end
  end

  test "does not enqueue image derivative job for videos" do
    assert_no_enqueued_jobs only: GeneratePhotoDerivativesJob do
      photo = users(:one).photos.new
      photo.original.attach(
        io: StringIO.new("fake mov bytes"),
        filename: "clip.mov",
        content_type: "video/quicktime"
      )
      photo.save!
    end
  end

  test "publishes and unpublishes" do
    photo = attached_photo

    photo.publish!
    assert_predicate photo, :public?
    assert_predicate photo.published_at, :present?

    photo.unpublish!
    assert_predicate photo, :private?
    assert_nil photo.published_at
  end

  private

  def attached_photo(**attributes)
    photo = users(:one).photos.new(**attributes)
    photo.original.attach(
      io: File.open(Rails.root.join("public/icon.png")),
      filename: "fixture.png",
      content_type: "image/png"
    )
    photo.save!
    photo
  end
end
