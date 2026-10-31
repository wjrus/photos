require "minitest/autorun"
require "open3"
require "tmpdir"
require "fileutils"
require "pathname"
require "digest"

# These exercise the shell tools with synthetic repositories and a fake Docker/
# SSH boundary. They never contact a host or use the developer's Docker daemon.
class MigrationTest < Minitest::Test
  REPO = Pathname.new(__dir__).join("../..").expand_path
  IDENTITY = "a" * 64

  def setup
    @temporary = Dir.mktmpdir("photos-migration-test")
    @root = Pathname.new(@temporary).realpath
    @source = @root.join("source")
    @bin = @root.join("bin")
    @app = @root.join("target/apps/photos")
    @storage = @root.join("target/app_storage")
    @imports = @root.join("target/imports")
    @state = @root.join("target/photos-migration")
    [ @source, @bin, @app, @storage, @imports, @state, @source.join("storage"), @source.join("imports") ].each(&:mkpath)
    FileUtils.cp_r(REPO.join("scripts"), @source)
    @source.join(".gitignore").write(".env*\n")
    @source.join("compose.yml").write("services: {}\n")
    @source.join(".env.production").write("PHOTOS_STORAGE_PATH=#{@source}/storage\nPHOTOS_IMPORT_PATH=#{@source}/imports\n")
    @source.join(".env.postgres").write("POSTGRES_PASSWORD=synthetic-test-only\n")
    git(@source, "init", "-q", "-b", "main")
    git(@source, "config", "user.name", "Migration Test")
    git(@source, "config", "user.email", "alice@example.com")
    git(@source, "add", ".")
    git(@source, "commit", "-qm", "Synthetic source")
    git(@source, "remote", "add", "origin", "https://example.com/photos.git")
    @environment = {
      "PATH" => "#{@bin}:#{ENV.fetch('PATH')}",
      "MIGRATION_TEST_ROOT" => @root.to_s,
      "MIGRATION_SOURCE_STATE" => @root.join("source-state").to_s,
      "MIGRATION_TARGET_STATE" => @state.to_s,
      "MIGRATION_TARGET_APP" => @app.to_s,
      "MIGRATION_TARGET_STORAGE" => @storage.to_s,
      "MIGRATION_TARGET_IMPORTS" => @imports.to_s,
      "MIGRATION_COPY_IMPORTS" => "1",
      "MIGRATION_APP_ROOT" => @source.to_s,
      "PHOTOS_STORAGE_PATH" => nil,
      "PHOTOS_IMPORT_PATH" => nil,
      "COMPOSE_PROFILES" => nil
    }
    write_command("docker", <<~'BASH')
      printf 'docker %s\n' "$*" >> "$MIGRATION_TEST_ROOT/calls"
      if [[ "${1:-} ${2:-} ${3:-}" == 'compose ps --all' ]]; then
        printf '%s\n' "${*: -1}-container"
      elif [[ "$1" == inspect ]]; then
        case "$3" in
          *Config.Labels*) printf '%s\n' "${MIGRATION_TEST_PROJECT:-photos}" ;;
          *'/rails/storage'*) printf '%s/source/storage\n' "$MIGRATION_TEST_ROOT" ;;
          *'/analysis'*) printf 'photos_analysis_index\n' ;;
          *'/models'*) printf 'photos_analysis_model_cache\n' ;;
          *) printf 'sha256:synthetic\n' ;;
        esac
      elif [[ "$1" == ps && "$*" == *'--format'* ]]; then
        printf '%s\n' "${MIGRATION_TEST_RUNNING:-db}"
      elif [[ "$1" == events && "${MIGRATION_TEST_RESTARTED:-0}" == 1 ]]; then
        printf 'worker\n'
      elif [[ "$1" == exec && "$*" == *'server_version_num'* ]]; then
        printf '180006\n'
      elif [[ "$1" == exec && "$*" == *'pg_database_size'* ]]; then
        printf '1024\n'
      elif [[ "$1" == exec && "$*" == *'FROM pg_tables'* ]]; then
        printf '%s\n' "${MIGRATION_TEST_TABLES:-0}"
      elif [[ "$1" == exec && "$*" == *'SELECT 1 FROM pg_database'* ]]; then
        printf '1\n'
      elif [[ "$1" == exec && "$*" == *"SELECT 'photos'"* ]]; then
        printf 'attachments|3\nblob_bytes|100\nblobs|3\nphotos|1\n'
      elif [[ "$1" == exec && "$*" == *pg_dump* ]]; then
        printf 'synthetic-dump\n'
      elif [[ "$1" == exec && "$*" == *pg_restore* ]]; then
        cat >/dev/null
      elif [[ "${1:-} ${2:-}" == 'volume inspect' ]]; then
        exit 1
      elif [[ "$1" == run && "$*" == *'-xf -'* ]]; then
        cat >/dev/null
      elif [[ "$1" == run || "$1" == cp ]]; then
        tar -cf - -T /dev/null
      fi
    BASH
    write_command("ssh", <<~'BASH')
      printf 'ssh %s\n' "$*" >> "$MIGRATION_TEST_ROOT/calls"
      if [[ "$*" == *'migration-target ready '* && "${MIGRATION_TEST_NOT_READY:-0}" == 1 ]]; then exit 44; fi
    BASH
    write_command("rsync", <<~'BASH')
      printf 'rsync %s\n' "$*" >> "$MIGRATION_TEST_ROOT/calls"
      if [[ "${MIGRATION_TEST_RSYNC_FAILURE:-0}" == 1 && "$*" == *'--rsync-path='* ]]; then exit 23; fi
      if [[ "${MIGRATION_TEST_DIFFERENT:-0}" == 1 && "$*" == *'--dry-run'* ]]; then printf '>f.s.......\n'; fi
    BASH
    write_command("sudo", '[[ "${1:-}" != -n ]] || shift; exec "$@"')
    write_command("df", "printf 'Filesystem 1-blocks Used Available Capacity Mounted\\nsynthetic 2000000000000 0 2000000000000 0%% /\\n'")
    write_command("flock", "exit 0")
    # The tools intentionally require Linux. This adapter permits the safety
    # tests to run on macOS too; existing symlinks are still resolved.
    @bin.join("realpath").write(<<~RUBY)
      #!#{RbConfig.ruby}
      require "pathname"
      path = Pathname.new(ARGV.last)
      missing = []
      until path.exist?
        missing.unshift(path.basename.to_s)
        path = path.parent
      end
      puts path.realpath.join(*missing).cleanpath
    RUBY
    @bin.join("realpath").chmod(0o755)
  end

  def teardown
    FileUtils.remove_entry(@temporary)
  end

  def test_final_transfer_requires_explicit_stop_acknowledgement
    output, status = source_command("final-sync", "alice@new.example.com")
    refute status.success?, output
    assert_includes output, "--confirm-stop-source"
    assert_empty calls
  end

  def test_destination_shell_characters_are_rejected_before_remote_access
    output, status = source_command("preflight", "alice@new.example.com;touch /tmp/unwanted")
    refute status.success?, output
    assert_includes output, "invalid SSH destination"
    assert_empty calls
  end

  def test_wrong_compose_project_cannot_be_migrated
    output, status = source_command("preflight", "alice@new.example.com", extra: { "MIGRATION_TEST_PROJECT" => "another_app" })
    refute status.success?, output
    assert_includes output, "expected the Photos Compose project"
    refute_includes calls, "ssh "
  end

  def test_live_sync_exports_all_databases_and_both_cache_locations_without_stopping_services
    output, status = source_command("sync", "alice@new.example.com")
    assert status.success?, output
    %w[photos_production photos_production_queue photos_production_cache photos_production_cable].each do |database|
      assert_includes calls, "--no-acl #{database}"
    end
    assert_includes calls, "photos_analysis_index"
    assert_includes calls, "photos_analysis_model_cache"
    assert_includes calls, "analysis-local-container:/root/.cache/."
    refute_includes calls, "compose stop"
    assert_includes calls, "migration-target complete"
  end

  def test_target_readiness_failure_does_not_stop_source
    @root.join("source-state").mkpath
    @root.join("source-state/synced").write("")
    output, status = source_command("final-sync", "--confirm-stop-source", "alice@new.example.com", extra: { "MIGRATION_TEST_NOT_READY" => "1" })
    refute status.success?, output
    refute_includes calls, "compose stop"
  end

  def test_final_sync_stops_only_photos_writers_before_dumping
    @root.join("source-state").mkpath
    @root.join("source-state/synced").write("")
    output, status = source_command("final-sync", "--confirm-stop-source", "alice@new.example.com")
    assert status.success?, output
    assert_operator calls.index("compose stop -t 120 app_proxy web_blue web_green"), :<, calls.index("compose stop -t 900 worker")
    assert_operator calls.index("compose stop -t 120 analysis-local"), :<, calls.index("pg_dump")
    refute_match(/compose (?:down|start|up)/, calls)
    refute_includes calls, "plex"
  end

  def test_failed_rsync_never_marks_transfer_complete_or_restarts_source
    @root.join("source-state").mkpath
    @root.join("source-state/synced").write("")
    output, status = source_command("final-sync", "--confirm-stop-source", "alice@new.example.com", extra: { "MIGRATION_TEST_RSYNC_FAILURE" => "1" })
    refute status.success?, output
    refute_includes calls, "migration-target complete"
    refute_match(/compose (?:start|up)/, calls)
  end

  def test_source_restart_during_freeze_invalidates_final_snapshot
    @root.join("source-state").mkpath
    @root.join("source-state/synced").write("")
    output, status = source_command("final-sync", "--confirm-stop-source", "alice@new.example.com", extra: { "MIGRATION_TEST_RESTARTED" => "1" })
    refute status.success?, output
    assert_includes output, "containers started during the write freeze"
    refute_includes calls, "migration-target complete"
  end

  def test_checksum_verification_reports_a_file_difference
    output, status = source_command("verify", "alice@new.example.com", extra: { "MIGRATION_TEST_DIFFERENT" => "1" })
    refute status.success?, output
    assert_includes output, "storage differs"
    assert_includes calls, "--checksum"
  end

  def test_target_initialization_refuses_existing_files
    @storage.join("keep-this").write("synthetic original")
    output, status = target_command("init")
    refute status.success?, output
    assert_includes output, "not empty"
    assert @storage.join("keep-this").exist?
    refute @state.join("identity").exist?
  end

  def test_restoration_cannot_be_overwritten_by_another_sync
    initialize_target
    @state.join("restore-started").write("")
    output, status = target_command("begin")
    refute status.success?, output
    assert_includes output, "restoration already started"
    refute @state.join("incoming").exist?
  end

  def test_rehearsal_snapshot_cannot_be_restored
    initialize_target
    payload("sync")
    output, status = target_command("restore")
    refute status.success?, output
    assert_includes output, "only a final-sync"
    refute_includes calls, "compose up"
  end

  def test_payload_tampering_is_detected_before_any_database_operation
    initialize_target
    payload("final-sync")
    @state.join("payload/mode").write("tampered\n")
    output, status = target_command("restore")
    refute status.success?, output
    refute_includes calls, "compose up"
  end

  def test_restore_refuses_nonempty_databases_without_dropping_anything
    prepare_restore
    output, status = target_command("restore", extra: { "MIGRATION_TEST_TABLES" => "1" })
    refute status.success?, output
    assert_includes output, "refusing to overwrite"
    refute_includes calls, "pg_restore"
    refute_match(/dropdb|DROP DATABASE|--clean/, calls)
  end

  def test_restore_preserves_counts_and_never_starts_writers
    prepare_restore
    output, status = target_command("restore")
    assert status.success?, output
    assert @state.join("restored").exist?
    assert_equal 4, calls.scan("pg_restore").length
    assert_includes calls, "--single-transaction --no-owner --no-acl"
    assert_includes calls, "compose up -d --wait --wait-timeout 120 db redis"
    refute_match(/compose up.*(?:worker|web_blue|web_green|analysis-local)/, calls)
    output, status = target_command("verify")
    assert status.success?, output
  end

  def test_restoring_a_final_payload_requires_building_its_final_configuration
    prepare_restore
    @state.join("built-payload").write("stale\n")
    output, status = target_command("restore")
    refute status.success?, output
    assert_includes output, "final snapshot configuration"
    refute_includes calls, "compose up"
  end

  def test_workers_require_an_explicit_activation_flag
    initialize_target
    output, status = target_command("activate")
    refute status.success?, output
    assert_includes output, "MIGRATION_ENABLE_WORKERS=1"
    refute_includes calls, "compose up"
  end

  def test_build_preserves_commits_made_on_the_target
    initialize_target
    @source.children.each { |entry| FileUtils.cp_r(entry, @app) }
    payload("sync")
    @state.join("built").write("#{git(@source, 'rev-parse', 'HEAD')}\n")
    @app.join("local-fix.txt").write("synthetic local work\n")
    git(@app, "add", "local-fix.txt")
    git(@app, "commit", "-qm", "Preserve local work")
    revision = git(@app, "rev-parse", "HEAD")
    output, status = target_command("build")
    refute status.success?, output
    assert_includes output, "branch advanced outside the migration"
    assert_equal revision, git(@app, "rev-parse", "HEAD")
    assert @app.join("local-fix.txt").exist?
  end

  def test_build_restores_the_exact_revision_and_private_configuration_without_starting_services
    initialize_target
    payload("sync")
    directory = @state.join("payload")
    directory.join("secrets/config").mkpath
    FileUtils.cp(@source.join(".env.production"), directory.join("secrets/.env.production"))
    FileUtils.cp(@source.join(".env.postgres"), directory.join("secrets/.env.postgres"))
    directory.join("secrets/.env.production").open("a") { |file| file.puts "SECRET_KEY_BASE=synthetic-signing-key" }
    directory.join("origin").write("https://example.com/photos.git\n")
    git(@source, "bundle", "create", directory.join("source.bundle").to_s, "HEAD", "refs/heads/main")
    seal_payload(directory)

    2.times do
      output, status = target_command("build")
      assert status.success?, output
    end
    assert_equal git(@source, "rev-parse", "HEAD"), git(@app, "rev-parse", "HEAD")
    assert_equal 0o600, @app.join(".env.production").stat.mode & 0o777
    assert_includes @app.join(".env.production").read, "SECRET_KEY_BASE=synthetic-signing-key"
    assert_includes @app.join(".env.production").read, "PHOTOS_STORAGE_PATH=#{@storage}"
    assert_includes @app.join("compose.override.yml").read, "127.0.0.1:3000:80"
    refute_includes calls, "compose up"
  end

  private

  def git(directory, *arguments)
    output, status = Open3.capture2e("git", "-C", directory.to_s, *arguments)
    raise output unless status.success?
    output.strip
  end

  def write_command(name, body)
    file = @bin.join(name)
    file.write("#!/usr/bin/env bash\nset -eu\n#{body}\n")
    file.chmod(0o755)
  end

  def calls
    @root.join("calls").exist? ? @root.join("calls").read : ""
  end

  def source_command(*arguments, extra: {})
    Open3.capture2e(@environment.merge(extra), "bash", @source.join("scripts/migrate-host").to_s, *arguments)
  end

  def target_command(action, extra: {})
    Open3.capture2e(@environment.merge(extra), "bash", REPO.join("scripts/migration-target").to_s,
      action, IDENTITY, @app.to_s, @storage.to_s, @imports.to_s, @state.to_s)
  end

  def initialize_target
    output, status = target_command("init")
    assert status.success?, output
  end

  def payload(mode)
    directory = @state.join("payload")
    directory.mkpath
    directory.join("mode").write("#{mode}\n")
    directory.join("revision").write("#{git(@source, 'rev-parse', 'HEAD')}\n")
    directory.join("counts").write("attachments|3\nblob_bytes|100\nblobs|3\nphotos|1\n")
    %w[photos_production photos_production_queue photos_production_cache photos_production_cable].each do |database|
      directory.join("#{database}.dump").write("synthetic dump\n")
    end
    %w[analysis_index analysis_model_cache analysis_download_cache].each { |name| directory.join("#{name}.tar").write("synthetic archive\n") }
    seal_payload(directory)
  end

  def seal_payload(directory)
    files = Dir.glob("**/*", File::FNM_DOTMATCH, base: directory).sort.select do |path|
      path != "SHA256SUMS" && directory.join(path).file?
    end
    sums = files.map { |path| "#{Digest::SHA256.file(directory.join(path)).hexdigest}  ./#{path}\n" }.join
    directory.join("SHA256SUMS").write(sums)
    @state.join("complete").write("#{Digest::SHA256.hexdigest(sums)}\n")
  end

  def prepare_restore
    initialize_target
    FileUtils.cp_r(@source.join(".git"), @app)
    payload("final-sync")
    @state.join("built").write("#{git(@source, 'rev-parse', 'HEAD')}\n")
    FileUtils.cp(@state.join("complete"), @state.join("built-payload"))
  end
end
