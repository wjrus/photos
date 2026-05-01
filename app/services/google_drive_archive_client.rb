require "google/apis/drive_v3"
require "googleauth"

class GoogleDriveArchiveClient
  DRIVE_SCOPE = "https://www.googleapis.com/auth/drive".freeze

  def initialize(user)
    @user = user
  end

  def upload_photo(photo)
    raise "GOOGLE_DRIVE_ARCHIVE_FOLDER_ID is not configured" if archive_folder_id.blank?
    raise "Google Drive is not authorized for #{user.email}" unless user.google_drive_authorized?

    service = Google::Apis::DriveV3::DriveService.new
    service.authorization = credentials

    photo.original.blob.open do |file|
      metadata = Google::Apis::DriveV3::File.new(
        name: archive_name(photo),
        parents: [ archive_folder_id ],
        description: "Original archive copy for wjr photos photo ##{photo.id}"
      )

      service.create_file(
        metadata,
        upload_source: file.path,
        content_type: photo.content_type,
        fields: "id,md5Checksum,size"
      )
    end
  end

  private

  attr_reader :user

  def credentials
    Google::Auth::UserRefreshCredentials.new(
      client_id: ENV.fetch("GOOGLE_CLIENT_ID"),
      client_secret: ENV.fetch("GOOGLE_CLIENT_SECRET"),
      scope: DRIVE_SCOPE,
      access_token: user.google_access_token,
      refresh_token: user.google_refresh_token,
      expires_at: user.google_token_expires_at&.to_i
    )
  end

  def archive_folder_id
    ENV["GOOGLE_DRIVE_ARCHIVE_FOLDER_ID"]
  end

  def archive_name(photo)
    [
      photo.id.to_s.rjust(8, "0"),
      photo.checksum_sha256,
      photo.original_filename
    ].compact_blank.join("-")
  end
end
