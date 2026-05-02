require "google/apis/drive_v3"
require "googleauth"

class GoogleDriveArchiveClient
  DRIVE_SCOPE = "https://www.googleapis.com/auth/drive".freeze
  APP_PROPERTY_PHOTO_ID = "wjrPhotosPhotoId".freeze
  APP_PROPERTY_SHA256 = "wjrPhotosSha256".freeze
  APP_PROPERTY_ORIGINAL_FILENAME = "wjrPhotosOriginalFilename".freeze

  def initialize(user, service: nil)
    @user = user
    @service = service
  end

  def upload_photo(photo)
    raise "GOOGLE_DRIVE_ARCHIVE_FOLDER_ID is not configured" if archive_folder_id.blank?
    raise "Google Drive is not authorized for #{user.email}" unless user.google_drive_authorized?

    service = drive_service

    existing_file = find_existing_archive_file(service, photo)
    return existing_file if existing_file

    photo.original.blob.open do |file|
      metadata = Google::Apis::DriveV3::File.new(
        name: archive_name(photo),
        parents: [ archive_folder_id ],
        description: "Original archive copy for wjr photos photo ##{photo.id}",
        app_properties: archive_app_properties(photo)
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

  attr_reader :user, :service

  def drive_service
    return service if service

    Google::Apis::DriveV3::DriveService.new.tap do |service|
      service.authorization = credentials
    end
  end

  def find_existing_archive_file(service, photo)
    response = service.list_files(
      q: archive_search_query(photo),
      page_size: 1,
      fields: "files(id,md5Checksum,size,name,appProperties)"
    )
    Array(response.files).first
  end

  def archive_search_query(photo)
    predicates = [ "name = '#{drive_query_escape(archive_name(photo))}'" ]
    if photo.checksum_sha256.present?
      predicates.unshift("appProperties has { key='#{APP_PROPERTY_SHA256}' and value='#{drive_query_escape(photo.checksum_sha256)}' }")
    end

    [
      "'#{drive_query_escape(archive_folder_id)}' in parents",
      "trashed = false",
      "(#{predicates.join(' or ')})"
    ].join(" and ")
  end

  def archive_app_properties(photo)
    {
      APP_PROPERTY_PHOTO_ID => photo.id.to_s,
      APP_PROPERTY_ORIGINAL_FILENAME => photo.original_filename.to_s,
      APP_PROPERTY_SHA256 => photo.checksum_sha256.to_s
    }.compact_blank
  end

  def drive_query_escape(value)
    value.to_s.gsub("\\") { "\\\\" }.gsub("'") { "\\'" }
  end

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
