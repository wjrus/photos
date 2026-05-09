class ApplicationJob < ActiveJob::Base
  ORIGINAL_FILE_LOCK_NAMESPACE = 54_214
  ORIGINAL_FILE_HEALTH_AUTO_HEAL_ENV = "ORIGINAL_FILE_HEALTH_AUTO_HEAL".freeze

  # Automatically retry jobs that encountered a deadlock
  # retry_on ActiveRecord::Deadlocked

  # Most jobs are safe to ignore if the underlying records are no longer available
  # discard_on ActiveJob::DeserializationError

  private

  def with_original_file_lock(blob)
    connection = ActiveRecord::Base.connection
    return yield unless connection.adapter_name == "PostgreSQL"

    lock_id = Integer(blob.id)
    original_file_lock_query("SELECT pg_advisory_lock($1, $2)", lock_id)
    yield
  ensure
    if connection&.adapter_name == "PostgreSQL" && lock_id
      original_file_lock_query("SELECT pg_advisory_unlock($1, $2)", lock_id)
    end
  end

  def original_file_lock_query(sql, lock_id)
    integer_type = ActiveRecord::Type::Integer.new
    ActiveRecord::Base.connection.exec_query(sql, "SQL", [
      ActiveRecord::Relation::QueryAttribute.new("namespace", ORIGINAL_FILE_LOCK_NAMESPACE, integer_type),
      ActiveRecord::Relation::QueryAttribute.new("lock_id", lock_id, integer_type)
    ])
  end

  def original_file_auto_heal_enabled?
    ActiveModel::Type::Boolean.new.cast(ENV.fetch(ORIGINAL_FILE_HEALTH_AUTO_HEAL_ENV, "false"))
  end
end
