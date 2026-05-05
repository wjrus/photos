class QueueStatusSnapshot
  EXECUTION_STATES = {
    ready: { table: "solid_queue_ready_executions", queue_column: true },
    claimed: { table: "solid_queue_claimed_executions", queue_column: false },
    scheduled: { table: "solid_queue_scheduled_executions", queue_column: true },
    failed: { table: "solid_queue_failed_executions", queue_column: false },
    blocked: { table: "solid_queue_blocked_executions", queue_column: true }
  }.freeze

  attr_reader :generated_at

  def self.build
    new
  end

  def initialize(connection: default_connection, generated_at: Time.current)
    @connection = connection
    @generated_at = generated_at
  end

  def available?
    table_exists?("solid_queue_jobs")
  end

  def totals
    return empty_totals unless available?

    EXECUTION_STATES.transform_values { |definition| count_rows(definition[:table]) }
  end

  def queues
    return [] unless available?

    rows = Hash.new { |hash, key| hash[key] = empty_totals.dup }
    EXECUTION_STATES.each do |state, definition|
      grouped_counts(definition).each do |queue_name, count|
        rows[queue_name][state] = count
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
    EXECUTION_STATES.each do |state, definition|
      grouped_job_classes(definition).each do |class_name, count|
        rows[class_name][state] = count
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

    select_all(<<~SQL.squish)
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

  def processes
    return [] unless available? && table_exists?("solid_queue_processes")

    select_all(<<~SQL.squish)
      SELECT id, kind, name, pid, hostname, last_heartbeat_at, created_at
      FROM #{quote_table("solid_queue_processes")}
      ORDER BY last_heartbeat_at DESC
    SQL
  end

  def pauses
    return [] unless available? && table_exists?("solid_queue_pauses")

    select_all(<<~SQL.squish)
      SELECT queue_name, created_at
      FROM #{quote_table("solid_queue_pauses")}
      ORDER BY queue_name ASC
    SQL
  end

  def finished_counts
    return { last_hour: 0, last_day: 0 } unless available?

    {
      last_hour: finished_since(1.hour.ago),
      last_day: finished_since(1.day.ago)
    }
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

  def count_rows(table)
    return 0 unless table_exists?(table)

    connection.select_value("SELECT COUNT(*) FROM #{quote_table(table)}").to_i
  end

  def grouped_counts(definition)
    table = definition[:table]
    return {} unless table_exists?(table)

    if definition[:queue_column]
      rows = select_all(<<~SQL.squish)
        SELECT queue_name, COUNT(*) AS count
        FROM #{quote_table(table)}
        GROUP BY queue_name
      SQL
    else
      rows = select_all(<<~SQL.squish)
        SELECT jobs.queue_name, COUNT(*) AS count
        FROM #{quote_table(table)} executions
        INNER JOIN #{quote_table("solid_queue_jobs")} jobs ON jobs.id = executions.job_id
        GROUP BY jobs.queue_name
      SQL
    end

    rows.to_h { |row| [ row.fetch("queue_name"), row.fetch("count").to_i ] }
  end

  def grouped_job_classes(definition)
    table = definition[:table]
    return {} unless table_exists?(table)

    rows = select_all(<<~SQL.squish)
      SELECT jobs.class_name, COUNT(*) AS count
      FROM #{quote_table(table)} executions
      INNER JOIN #{quote_table("solid_queue_jobs")} jobs ON jobs.id = executions.job_id
      GROUP BY jobs.class_name
    SQL

    rows.to_h { |row| [ row.fetch("class_name"), row.fetch("count").to_i ] }
  end

  def finished_since(time)
    connection.select_value(
      ActiveRecord::Base.sanitize_sql([
        "SELECT COUNT(*) FROM #{quote_table('solid_queue_jobs')} WHERE finished_at >= ?",
        time
      ])
    ).to_i
  end

  def select_all(sql)
    connection.select_all(sql).to_a
  end

  def table_exists?(table)
    connection.data_source_exists?(table)
  end

  def quote_table(table)
    connection.quote_table_name(table)
  end
end
