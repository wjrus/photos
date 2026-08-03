namespace :photos do
  desc "Recursively import photos and videos from a mounted directory"
  task import_directory: :environment do
    $stdout.sync = true
    $stderr.sync = true

    path = ENV.fetch("DIRECTORY_IMPORT_PATH", ENV.fetch("PHOTOS_DIRECTORY_IMPORT_PATH", "/rails/imports/inbox"))
    owner_email = ENV.fetch("OWNER_EMAIL", ENV["PHOTOS_OWNER_EMAIL"])
    owner = User.find_by!(email: owner_email)
    dry_run = ActiveModel::Type::Boolean.new.cast(ENV["DRY_RUN"])
    verbose = ActiveModel::Type::Boolean.new.cast(ENV["VERBOSE"])

    summary = PhotoDirectoryImporter.new(
      owner: owner,
      logger: Rails.logger,
      output: $stdout,
      dry_run: dry_run,
      verbose: verbose
    ).import_path(path)

    puts(dry_run ? "Directory import dry run complete" : "Directory import complete")
    puts "path: #{Pathname(path).expand_path}"
    summary.except(:errors).each { |key, value| puts "#{key}: #{value}" }
    summary.fetch(:errors).each { |error| warn "error: #{error}" }

    abort "Directory import completed with failures" if summary.fetch(:failed).positive?
  end
end
