require "test_helper"
require_relative "../support/photo_book_test_helper"

class PreparePhotoBookExportJobTest < ActiveSupport::TestCase
  include PhotoBookTestHelper

  test "export embeds fonts and RGB original artwork at the exact book size" do
    book, photo = book_with_photo(print_ready: true)
    book.update!(cover_photo: photo)
    export = pending_book_export(book)
    PreparePhotoBookExportJob.perform_now(export)
    assert export.reload.ready?, export.error
    assert_equal 20, export.processed_pages
    bytes = export.document.download
    assert bytes.start_with?("%PDF-")
    assert_equal 20, bytes.scan(/\/Type\s+\/Page\b/).size
    assert_match(/\/FontFile2\s+\d+\s+0\s+R/, bytes)
    assert_includes bytes, "/DeviceRGB"
    media_box = bytes.match(/\/MediaBox\s+\[([^\]]+)\]/)[1].split.map(&:to_f)
    assert_in_delta 210 * 72.0 / 25.4, media_box[2], 0.01
    assert_in_delta media_box[2], media_box[3], 0.01
    attachment_id = export.document.id
    PreparePhotoBookExportJob.perform_now(export)
    assert_equal attachment_id, export.reload.document.id
  end

  test "export captures saved captions and fails if sources become private" do
    book, photo = book_with_photo(print_ready: true)
    export = pending_book_export(book)
    book.pages.first.update!(caption: "Changed after queuing")
    assert_equal "Beside the lake.", export.snapshot.fetch("pages").first.fetch("caption")
    photo.update!(restricted: true)
    PreparePhotoBookExportJob.perform_now(export)
    assert_equal "failed", export.reload.status
    assert_not export.document.attached?
  end

  test "styled covers embed their selected fonts and a queued export keeps its typography" do
    book, photo = book_with_photo(print_ready: true)
    book.update!(cover_photo: photo, cover_layout: "full", back_text: "Summer · Été",
      cover_style: { font: "garamond_italic", size: 42, color: "#fff5e1", shadow: true, shadow_color: "#112233" },
      back_style: { font: "serif", size: 20, shadow: false })
    book.pages.first.update!(show_captions: false, caption: "Hidden text 🚀")
    export = pending_book_export(book)
    book.update!(cover_style: { font: "lato", size: 20 })
    PreparePhotoBookExportJob.perform_now(export)
    assert export.reload.ready?, export.error
    bytes = export.document.download
    assert_includes bytes, "CormorantGaramond-Italic"
    assert_includes bytes, "NotoSerif-Regular"
    assert_not_includes bytes, "Lato-Light"
    assert_equal "garamond_italic", export.snapshot.fetch("cover_style").fetch("font")
  end

  test "actual original resolution is checked even when metadata claims higher resolution" do
    book, photo = book_with_photo(print_ready: true)
    photo.metadata.update!(width: 12000, height: 8000)
    export = pending_book_export(book, allow_low_resolution: false)
    PreparePhotoBookExportJob.perform_now(export)
    assert_equal "failed", export.reload.status
    assert_includes export.error, "DPI"
  end

  test "a retried processing export recovers and completes" do
    book, = book_with_photo(print_ready: true)
    export = pending_book_export(book)
    export.update!(status: "processing")
    PreparePhotoBookExportJob.perform_now(export)
    assert export.reload.ready?, export.error
  end

  test "an export becomes ready only after its PDF has uploaded" do
    book, = book_with_photo(print_ready: true)
    export = pending_book_export(book)
    checked_upload = ->(_event) do
      assert_equal "processing", export.reload.status
      assert_not export.document.attached?
    end
    ActiveSupport::Notifications.subscribed(checked_upload, "service_upload.active_storage") do
      PreparePhotoBookExportJob.perform_now(export)
    end
    assert export.reload.ready?
    assert export.document.download.start_with?("%PDF-")
  end

  test "deleting a book during upload discards the export and its uploaded PDF" do
    book, = book_with_photo(print_ready: true)
    export = pending_book_export(book)
    uploaded_blob = nil
    delete_during_upload = ->(event) do
      uploaded_blob = ActiveStorage::Blob.find_by!(key: event.payload.fetch(:key))
      book.destroy!
    end
    ActiveSupport::Notifications.subscribed(delete_during_upload, "service_upload.active_storage") do
      PreparePhotoBookExportJob.perform_now(export)
    end
    assert_not PhotoBookExport.exists?(export.id)
    assert_not ActiveStorage::Blob.exists?(uploaded_blob.id)
    assert_not uploaded_blob.service.exist?(uploaded_blob.key)
  end
end
