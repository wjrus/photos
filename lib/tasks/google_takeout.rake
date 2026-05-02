namespace :google_takeout do
  desc "Import Google Photos Takeout zip files from a mounted path"
  task :import, [ :path, :owner_email ] => :environment do |_task, args|
    path = args[:path].presence || "/rails/imports/google-takeout"
    owner_email = args[:owner_email].presence || ENV["PHOTOS_OWNER_EMAIL"]
    owner = User.find_by!(email: owner_email)

    summary = GoogleTakeoutImporter.new(owner: owner, logger: Rails.logger).import_path(path)

    puts "Google Takeout import complete"
    summary.each do |key, value|
      puts "#{key}: #{value}"
    end
  end
end
