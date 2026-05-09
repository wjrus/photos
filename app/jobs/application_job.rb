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
    connection.execute("SELECT pg_advisory_lock(#{ORIGINAL_FILE_LOCK_NAMESPACE}, #{lock_id})")
    yield
  ensure
    if connection&.adapter_name == "PostgreSQL" && lock_id
      connection.execute("SELECT pg_advisory_unlock(#{ORIGINAL_FILE_LOCK_NAMESPACE}, #{lock_id})")
    end
  end

  def original_file_auto_heal_enabled?
    ActiveModel::Type::Boolean.new.cast(ENV.fetch(ORIGINAL_FILE_HEALTH_AUTO_HEAL_ENV, "false"))
  end
end
