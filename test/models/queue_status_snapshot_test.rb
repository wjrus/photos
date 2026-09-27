require "test_helper"
require "delegate"

class QueueStatusSnapshotTest < ActiveSupport::TestCase
  class RecordingConnection < SimpleDelegator
    attr_reader :table_checks

    def initialize(connection)
      super
      @table_checks = Hash.new(0)
    end

    def data_source_exists?(table)
      @table_checks[table] += 1
      super
    end
  end

  setup do
    @connection = RecordingConnection.new(SolidQueue::Job.connection)
    @now = Time.current.change(usec: 0)
    @snapshot = QueueStatusSnapshot.new(connection: @connection, generated_at: @now)
  end

  test "queue and job class breakdowns share five execution aggregates" do
    create_queue_tables
    2.times { add_execution(:ready, queue: "archive", job_class: "ArchiveJob") }
    add_execution(:ready, queue: "analysis", job_class: "AnalysisJob")
    add_execution(:claimed, queue: "archive", job_class: "ArchiveJob")
    add_execution(:scheduled, queue: "archive", job_class: "ArchiveJob")
    2.times { add_execution(:failed, queue: "analysis", job_class: "AnalysisJob") }
    add_execution(:blocked, queue: "analysis", job_class: "AnalysisJob")

    queries = capture_queries do
      2.times do
        assert_equal({ ready: 3, claimed: 1, scheduled: 1, failed: 2, blocked: 1 }, @snapshot.totals)
        assert_equal [ "analysis", "archive" ], @snapshot.queues.pluck(:name)
        assert_equal [ 4, 4 ], @snapshot.queues.pluck(:total)
        assert_equal [ "AnalysisJob", "ArchiveJob" ], @snapshot.job_classes.pluck(:name)
        assert_equal [ 4, 4 ], @snapshot.job_classes.pluck(:total)
        assert_equal({ ready: 1, claimed: 0, scheduled: 0, failed: 2, blocked: 1 }, @snapshot.job_classes.first[:counts])
      end
    end

    assert_equal 5, queries.count { |sql| sql.include?("GROUP BY") }, queries.join("\n")
    assert_equal 5, queries.size, queries.join("\n")
    assert_equal 6, @connection.table_checks.size
    assert @connection.table_checks.values.all? { |count| count == 1 }, @connection.table_checks.inspect
  end

  test "queue breakdown uses execution queue names when the state has its own queue column" do
    create_queue_tables
    add_execution(:ready, queue: "original", job_class: "ArchiveJob")
    @connection.execute("UPDATE solid_queue_ready_executions SET queue_name = 'current'")

    assert_equal [ "current" ], @snapshot.queues.pluck(:name)
    assert_equal 1, @snapshot.totals[:ready]
    assert_equal "ArchiveJob", @snapshot.job_classes.first[:name]
  end

  test "finished windows use one query and include their cutoff times" do
    create_queue_tables
    [ @now - 1.hour, @now - 1.hour - 1.second, @now - 1.day, @now - 1.day - 1.second, nil ].each do |finished_at|
      add_job(finished_at: finished_at)
    end

    queries = capture_queries do
      2.times { assert_equal({ last_hour: 1, last_day: 3 }, @snapshot.finished_counts) }
    end

    assert_equal 1, queries.size, queries.join("\n")
    assert_equal 1, @connection.table_checks.fetch("solid_queue_jobs")
  end

  test "missing queue tables return empty results without repeated schema lookups" do
    2.times do
      assert_not @snapshot.available?
      assert_equal zero_totals, @snapshot.totals
      assert_empty @snapshot.queues
      assert_empty @snapshot.job_classes
      assert_empty @snapshot.recent_failures
      assert_empty @snapshot.pauses
      assert_empty @snapshot.processes
      assert_equal 0, @snapshot.pruned_failure_count
      assert_equal({ last_hour: 0, last_day: 0 }, @snapshot.finished_counts)
    end

    assert_equal({ "solid_queue_jobs" => 1 }, @connection.table_checks)
    assert_equal 0, @snapshot.clear_failures
    assert_equal 0, @snapshot.retry_pruned_failures
    assert_empty @snapshot.resume_paused_queues
    assert_not @snapshot.pause_queue("archive")
    assert_not @snapshot.resume_queue("archive")
  end

  test "missing execution tables do not prevent reading available states" do
    create_queue_tables(states: [ :ready ])
    add_execution(:ready)

    assert @snapshot.available?
    assert_equal zero_totals.merge(ready: 1), @snapshot.totals
    assert_equal 1, @snapshot.queues.first[:total]
    assert_equal 1, @snapshot.job_classes.first[:total]
    assert_empty @snapshot.recent_failures
    assert_equal 0, @snapshot.clear_failures
  end

  test "clearing failures invalidates counts and recent failures on the same snapshot" do
    create_queue_tables
    add_execution(:failed, error: pruned_error)
    add_execution(:failed)
    assert_equal 2, @snapshot.totals[:failed]
    assert_equal 2, @snapshot.recent_failures.size
    assert_equal 1, @snapshot.pruned_failure_count

    assert_equal 2, @snapshot.clear_failures

    assert_equal 0, @snapshot.totals[:failed]
    assert_empty @snapshot.recent_failures
    assert_equal 0, @snapshot.pruned_failure_count
  end

  test "retrying pruned failures refreshes the same snapshot and leaves other failures alone" do
    create_queue_tables
    add_execution(:failed, error: pruned_error)
    add_execution(:failed)
    assert_equal 2, @snapshot.totals[:failed]
    assert_equal 2, @snapshot.recent_failures.size
    assert_equal 1, @snapshot.pruned_failure_count

    assert_equal 1, @snapshot.retry_pruned_failures

    assert_equal 1, @snapshot.totals[:failed]
    assert_equal 1, @snapshot.totals[:ready]
    assert_equal 1, @snapshot.recent_failures.size
    assert_equal 0, @snapshot.pruned_failure_count
  end

  test "pause controls invalidate pause reads on the same snapshot" do
    create_queue_tables
    assert_empty @snapshot.pauses

    assert @snapshot.pause_queue("archive")
    assert_equal [ "archive" ], @snapshot.pauses.pluck("queue_name")
    assert @snapshot.resume_queue("archive")
    assert_empty @snapshot.pauses

    @snapshot.pause_queue("archive")
    @snapshot.pause_queue("analysis")
    assert_equal [ "analysis", "archive" ], @snapshot.resume_paused_queues
    assert_empty @snapshot.pauses
  end

  test "failure limits are cached separately and a new snapshot reads current state" do
    create_queue_tables
    3.times { add_execution(:failed) }

    queries = capture_queries do
      2.times do
        assert_equal 1, @snapshot.recent_failures(limit: 1).size
        assert_equal 2, @snapshot.recent_failures(limit: 2).size
      end
    end
    assert_equal 2, queries.size
    assert_equal 3, @snapshot.totals[:failed]

    add_execution(:failed)
    assert_equal 4, QueueStatusSnapshot.new(connection: @connection).totals[:failed]
  end

  private

  # Queue storage lives in a separate database in production. Temporary tables
  # let these tests exercise real SQL without changing the shared test schema.
  def create_queue_tables(states: QueueStatusSnapshot::EXECUTION_STATES.keys)
    @connection.execute("SET LOCAL search_path TO pg_temp, public")
    @connection.create_table(:solid_queue_jobs, temporary: true) do |table|
      table.string :queue_name, null: false
      table.string :class_name, null: false
      table.text :arguments
      table.integer :priority, default: 0, null: false
      table.string :active_job_id
      table.datetime :scheduled_at
      table.datetime :finished_at
      table.string :concurrency_key
      table.timestamps
    end

    states.each do |state|
      @connection.create_table(QueueStatusSnapshot::EXECUTION_STATES.fetch(state).fetch(:table), temporary: true) do |table|
        table.bigint :job_id, null: false
        table.string :queue_name
        table.integer :priority, default: 0
        table.text :error
        table.datetime :scheduled_at
        table.datetime :created_at, null: false
      end
    end

    @connection.create_table(:solid_queue_pauses, temporary: true) do |table|
      table.string :queue_name, null: false
      table.datetime :created_at, null: false
      table.index :queue_name, unique: true
    end
  end

  def add_job(queue: "archive", job_class: "ArchiveJob", finished_at: nil)
    @connection.select_value(ActiveRecord::Base.sanitize_sql_array([
      <<~SQL.squish,
        INSERT INTO solid_queue_jobs (queue_name, class_name, arguments, scheduled_at, finished_at, created_at, updated_at)
        VALUES (:queue, :class, :arguments, :now, :finished_at, :now, :now) RETURNING id
      SQL
      { queue: queue, class: job_class, arguments: { executions: 1, exception_executions: {} }.to_json, now: @now, finished_at: finished_at }
    ]))
  end

  def add_execution(state, queue: "archive", job_class: "ArchiveJob", error: { exception_class: "RuntimeError", message: "Synthetic failure" })
    job_id = add_job(queue: queue, job_class: job_class)
    table = @connection.quote_table_name(QueueStatusSnapshot::EXECUTION_STATES.fetch(state).fetch(:table))
    @connection.execute(ActiveRecord::Base.sanitize_sql_array([
      "INSERT INTO #{table} (job_id, queue_name, error, created_at) VALUES (:job_id, :queue, :error, :now)",
      { job_id: job_id, queue: queue, error: error.to_json, now: @now }
    ]))
  end

  def pruned_error
    { exception_class: QueueStatusSnapshot::PROCESS_PRUNED_EXCEPTION_CLASS, message: "Synthetic pruned process" }
  end

  def zero_totals
    { ready: 0, claimed: 0, scheduled: 0, failed: 0, blocked: 0 }
  end

  def capture_queries
    queries = []
    subscriber = ->(_name, _started, _finished, _unique_id, payload) do
      queries << payload[:sql] unless payload[:name] == "SCHEMA" || payload[:cached]
    end
    ActiveRecord::Base.uncached do
      ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") { yield }
    end
    queries
  end
end
