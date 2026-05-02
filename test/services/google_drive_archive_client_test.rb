require "test_helper"

class GoogleDriveArchiveClientTest < ActiveSupport::TestCase
  setup do
    @previous_folder_id = ENV["GOOGLE_DRIVE_ARCHIVE_FOLDER_ID"]
    @previous_client_id = ENV["GOOGLE_CLIENT_ID"]
    @previous_client_secret = ENV["GOOGLE_CLIENT_SECRET"]
    ENV["GOOGLE_DRIVE_ARCHIVE_FOLDER_ID"] = "drive-folder-123"
    ENV["GOOGLE_CLIENT_ID"] = "client-id"
    ENV["GOOGLE_CLIENT_SECRET"] = "client-secret"

    @owner = users(:one)
    @owner.update!(google_access_token: "access-token")
  end

  teardown do
    ENV["GOOGLE_DRIVE_ARCHIVE_FOLDER_ID"] = @previous_folder_id
    ENV["GOOGLE_CLIENT_ID"] = @previous_client_id
    ENV["GOOGLE_CLIENT_SECRET"] = @previous_client_secret
  end

  test "returns existing drive archive instead of uploading a duplicate" do
    existing_file = Google::Apis::DriveV3::File.new(
      id: "existing-file-id",
      md5_checksum: "existing-md5",
      size: 123
    )
    drive_service = FakeDriveService.new(existing_files: [ existing_file ])
    photo = attached_photo(checksum_sha256: "abc123")

    drive_file = GoogleDriveArchiveClient.new(@owner, service: drive_service).upload_photo(photo)

    assert_equal existing_file, drive_file
    assert_equal 1, drive_service.list_calls.size
    assert_empty drive_service.create_calls
    assert_includes drive_service.list_calls.first.fetch(:q), "appProperties has"
    assert_includes drive_service.list_calls.first.fetch(:q), "abc123"
  end

  test "uploads originals with archive app properties when no duplicate exists" do
    drive_service = FakeDriveService.new(existing_files: [])
    photo = attached_photo(checksum_sha256: "def456")

    drive_file = GoogleDriveArchiveClient.new(@owner, service: drive_service).upload_photo(photo)

    assert_equal "created-file-id", drive_file.id
    assert_equal 1, drive_service.create_calls.size

    metadata = drive_service.create_calls.first.fetch(:metadata)
    assert_equal [ "drive-folder-123" ], metadata.parents
    assert_equal "def456", metadata.app_properties.fetch(GoogleDriveArchiveClient::APP_PROPERTY_SHA256)
    assert_equal photo.id.to_s, metadata.app_properties.fetch(GoogleDriveArchiveClient::APP_PROPERTY_PHOTO_ID)
    assert_equal photo.original_filename, metadata.app_properties.fetch(GoogleDriveArchiveClient::APP_PROPERTY_ORIGINAL_FILENAME)
  end

  private

  class FakeDriveService
    attr_accessor :authorization
    attr_reader :list_calls, :create_calls

    def initialize(existing_files:)
      @existing_files = existing_files
      @list_calls = []
      @create_calls = []
    end

    def list_files(**options)
      list_calls << options
      Google::Apis::DriveV3::FileList.new(files: @existing_files)
    end

    def create_file(metadata, **options)
      create_calls << options.merge(metadata: metadata)
      Google::Apis::DriveV3::File.new(id: "created-file-id", md5_checksum: "created-md5", size: 456)
    end
  end

  def attached_photo(checksum_sha256:)
    photo = @owner.photos.new(checksum_sha256: checksum_sha256, checksum_status: "complete")
    photo.original.attach(
      io: File.open(Rails.root.join("public/icon.png")),
      filename: "fixture.png",
      content_type: "image/png"
    )
    photo.save!
    photo
  end
end
