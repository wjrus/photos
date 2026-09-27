class QueueStatusSnapshot
  EXECUTION_STATES = {
    ready: { table: "solid_queue_ready_executions", queue_column: true },
    claimed: { table: "solid_queue_claimed_executions", queue_column: false },
    scheduled: { table: "solid_queue_scheduled_executions", queue_column: true },
    failed: { table: "solid_queue_failed_executions", queue_column: false },
    blocked: { table: "solid_queue_blocked_executions", queue_column: true }
  }.freeze
  PROCESS_PRUNED_EXCEPTION_CLASS = "SolidQueue::Processes::ProcessPrunedError".freeze

  attr_reader :generated_at

  def self.build
    new
  end

  def initialize(connection: default_connection, generated_at: Time.current)
    @connection = connection
    @generated_at = generated_at
    @table_presence = {}
  end

  def available?
    table_exists?("solid_queue_jobs")
  end

  def totals
    return empty_totals unless available?

    execution_counts.transform_values { |rows| rows.sum { |row| row.fetch("count").to_i } }
  end

  def queues
    return [] unless available?

    rows = Hash.new { |hash, key| hash[key] = empty_totals.dup }
    execution_counts.each do |state, executions|
      executions.each do |execution|
        rows[execution.fetch("queue_name")][state] += execution.fetch("count").to_i
      end
    end

    rows.sort_by { |queue_name, _counts| queue_name.to_s }.map do |queue_name, counts|
      {
        name: queue_name,
        total: counts.values.sum,
        counts: counts
      }
    end
  end

  def job_classes
    return [] unless available?

    rows = Hash.new { |hash, key| hash[key] = empty_totals.dup }
    execution_counts.each do |state, executions|
      executions.each do |execution|
        rows[execution.fetch("class_name")][state] += execution.fetch("count").to_i
      end
    end

    rows.sort_by { |class_name, counts| [ -counts.values.sum, class_name.to_s ] }.map do |class_name, counts|
      {
        name: class_name,
        total: counts.values.sum,
        counts: counts
      }
    end
  end

  def recent_failures(limit: 20)
    return [] unless available? && table_exists?("solid_queue_failed_executions")

    @recent_failures ||= {}
    @recent_failures[Integer(limit)] ||= select_all(<<~SQL.squish)
      SELECT
        jobs.id,
        jobs.queue_name,
        jobs.class_name,
        jobs.active_job_id,
        failed.error,
        failed.created_at AS failed_at
      FROM #{quote_table("solid_queue_failed_executions")} failed
      INNER JOIN #{quote_table("solid_queue_jobs")} jobs ON jobs.id = failed.job_id
      ORDER BY failed.created_at DESC
      LIMIT #{Integer(limit)}
    SQL
  end

  def clear_failures
    return 0 unless available? && table_exists?("solid_queue_failed_executions")

    SolidQueue::FailedExecution.delete_all
  ensure
    reset_cached_results
  end

  def pruned_failure_count
    @pruned_failure_count ||= pruned_failures.count
  end

  def retry_pruned_failures
    failures = pruned_failures.includes(:job).to_a
    failures.each(&:retry)
    failures.size
  ensure
    reset_cached_results
  end

  def processes
    return [] unless available? && table_exists?("solid_queue_processes")

    @processes ||= select_all(<<~SQL.squish)
      SELECT id, kind, name, pid, hostname, last_heartbeat_at, created_at
      FROM #{quote_table("solid_queue_processes")}
      ORDER BY last_heartbeat_at DESC
    SQL
  end

  def pauses
    return [] unless available? && table_exists?("solid_queue_pauses")

    @pauses ||= select_all(<<~SQL.squish)
      SELECT queue_name, created_at
      FROM #{quote_table("solid_queue_pauses")}
      ORDER BY queue_name ASC
    SQL
  end

  def resume_paused_queues
    pause_names = pauses.map { |pause| pause.fetch("queue_name") }
    pause_names.each { |queue_name| SolidQueue::Queue.find_by_name(queue_name).resume }
    pause_names
  ensure
    reset_cached_results
  end

  def pause_queue(queue_name)
    return false unless available?

    SolidQueue::Queue.find_by_name(queue_name).pause
    true
  ensure
    reset_cached_results
  end

  def resume_queue(queue_name)
    return false unless available?

    SolidQueue::Queue.find_by_name(queue_name).resume
    true
  ensure
    reset_cached_results
  end

  def finished_counts
    return { last_hour: 0, last_day: 0 } unless available?

    @finished_counts ||= begin
      row = select_all(ActiveRecord::Base.sanitize_sql_array([
        <<~SQL.squish,
          SELECT COUNT(*) FILTER (WHERE finished_at >= :hour) AS last_hour, COUNT(*) AS last_day
          FROM #{quote_table("solid_queue_jobs")}
          WHERE finished_at >= :day
        SQL
        { hour: generated_at - 1.hour, day: generated_at - 1.day }
      ])).first
      { last_hour: row.fetch("last_hour").to_i, last_day: row.fetch("last_day").to_i }
    end
  end

  private

  attr_reader :connection

  def self.default_connection
    if defined?(SolidQueue::Job)
      SolidQueue::Job.connection
    else
      ActiveRecord::Base.connection
    end
  end

  def default_connection
    self.class.default_connection
  end

  def empty_totals
    EXECUTION_STATES.keys.index_with(0)
  end

  def execution_counts
    @execution_counts ||= EXECUTION_STATES.transform_values do |definition|
      table = definition.fetch(:table)
      next [] unless table_exists?(table)

      queue_column = definition.fetch(:queue_column) ? "executions.queue_name" : "jobs.queue_name"
      select_all(<<~SQL.squish)
        SELECT #{queue_column} AS queue_name, jobs.class_name, COUNT(*) AS count
        FROM #{quote_table(table)} executions
        INNER JOIN #{quote_table("solid_queue_jobs")} jobs ON jobs.id = executions.job_id
        GROUP BY #{queue_column}, jobs.class_name
      SQL
    end
  end

  def reset_cached_results
    @execution_counts = @finished_counts = @processes = @pauses = @recent_failures = @pruned_failure_count = nil
  end

  def select_all(sql)
    connection.select_all(sql).to_a
  end

  def pruned_failures
    return SolidQueue::FailedExecution.none unless available? && table_exists?("solid_queue_failed_executions")

    SolidQueue::FailedExecution.where("(error::jsonb ->> 'exception_class') = ?", PROCESS_PRUNED_EXCEPTION_CLASS)
  end

  def table_exists?(table)
    @table_presence.fetch(table) { @table_presence[table] = connection.data_source_exists?(table) }
  end

  def quote_table(table)
    connection.quote_table_name(table)
  end
end
