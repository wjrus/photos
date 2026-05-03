require "test_helper"
require "zip"

class GoogleTakeoutImportJobTest < ActiveJob::TestCase
  setup do
    @zip_path = Rails.root.join("tmp/google_takeout_import_job_test-#{Process.pid}-#{SecureRandom.hex(8)}.zip")
  end

  teardown do
    FileUtils.rm_f(@zip_path)
  end

  test "records a completed import run" do
    owner = users(:one)
    Zip::File.open(@zip_path.to_s, create: true) do |zip|
      zip.get_output_stream("Takeout/archive_browser.html") { |stream| stream.write("<html></html>") }
    end
    import_run = owner.google_takeout_import_runs.create!(path: @zip_path.to_s)

    GoogleTakeoutImportJob.perform_now(import_run)

    assert_equal "succeeded", import_run.reload.status
    assert_equal 1, import_run.summary.fetch("skipped")
    assert_not_nil import_run.started_at
    assert_not_nil import_run.finished_at
  end

  test "records a failed import run" do
    owner = users(:one)
    import_run = owner.google_takeout_import_runs.create!(path: "/rails/imports/missing")

    assert_raises(ArgumentError) { GoogleTakeoutImportJob.perform_now(import_run) }

    assert_equal "failed", import_run.reload.status
    assert_includes import_run.error, "No Google Takeout zip files found"
    assert_not_nil import_run.finished_at
  end
end
