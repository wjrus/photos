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

  desc "Queue a bounded OpenRouter vision-caption backfill (LIMIT=100 DRY_RUN=true)"
  task openrouter_backfill: :environment do
    $stdout.sync = true
    $stderr.sync = true

    limit = ENV.fetch("LIMIT", PhotoAnalysisOpenrouterBackfill::DEFAULT_LIMIT)
    dry_run = ActiveModel::Type::Boolean.new.cast(ENV["DRY_RUN"])
    result = PhotoAnalysisOpenrouterBackfill.new(output: $stdout).enqueue(limit:, dry_run:)

    puts(dry_run ? "OpenRouter backfill dry run complete" : "OpenRouter backfill queued")
    puts "eligible: #{result.eligible}"
    puts "requested: #{result.requested}"
    puts "queued: #{result.queued}"
    puts "spent: $#{format('%.4f', result.spend)}"
    puts "budget: $#{format('%.2f', result.budget)}"
    puts "remaining: $#{format('%.4f', result.remaining_budget)}"
    puts "estimated per photo: $#{format('%.4f', result.estimated_cost)}"
  rescue ArgumentError => error
    abort error.message
  end

  desc "Queue a fresh Qwen vision caption for one photo (photos:qwen[PHOTO_ID])"
  task :qwen, [ :photo_id ] => :environment do |_task, args|
    $stdout.sync = true
    $stderr.sync = true

    photo_id = Integer(args[:photo_id], exception: false)
    abort "Provide a numeric photo ID: bin/rails 'photos:qwen[PHOTO_ID]'" unless photo_id&.positive?
    abort "Enable OpenRouter Qwen vision captions in Repository Status first." unless AppSetting.boolean(AppSetting::ANALYSIS_OPENROUTER_ENABLED, default: false)
    abort "OPENROUTER_API_KEY is not configured." if ENV["OPENROUTER_API_KEY"].blank?

    photo = Photo.find_by(id: photo_id)
    abort "Photo #{photo_id} was not found." unless photo
    abort "Photo #{photo_id} is restricted; Qwen only analyzes unlocked photos." if photo.restricted?
    abort "Photo #{photo_id} is not a still image." unless photo.image?
    abort "Photo #{photo_id} has no attached original." unless photo.original.attached?

    job = PhotoAnalysisOpenrouterJob.perform_later(photo, force: true)
    puts "Queued Qwen caption regeneration for photo #{photo.id} on the vision queue (job #{job.job_id})."
  end
end
