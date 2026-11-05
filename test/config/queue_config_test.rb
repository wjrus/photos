require "test_helper"

class QueueConfigTest < ActiveSupport::TestCase
  test "workers include Solid Queue recurring jobs" do
    config = ERB.new(Rails.root.join("config/queue.yml").read).result
    workers = YAML.safe_load(config, aliases: true).fetch("production").fetch("workers")

    assert_includes workers.map { |worker| worker.fetch("queues") }, "solid_queue_recurring"
  end

  test "background polling is configurable while interactive queues stay responsive" do
    previous_interval = ENV.delete("BACKGROUND_JOB_POLL_INTERVAL")
    workers = queue_workers
    background, interactive = workers.partition { |worker| worker.fetch("queues").in?(%w[solid_queue_recurring import archive maintenance analysis vision]) }
    assert_equal 6, background.size
    assert background.all? { |worker| worker.fetch("polling_interval") == 2 }
    assert_equal 3, interactive.size
    assert interactive.all? { |worker| worker.fetch("polling_interval") == 0.5 }

    ENV["BACKGROUND_JOB_POLL_INTERVAL"] = "4"
    workers = queue_workers.index_by { |worker| worker.fetch("queues") }
    assert_equal 4, workers.fetch("maintenance").fetch("polling_interval")
    assert_equal 0.5, workers.fetch("derivatives").fetch("polling_interval")
  ensure
    ENV["BACKGROUND_JOB_POLL_INTERVAL"] = previous_interval
  end

  private

  def queue_workers
    config = ERB.new(Rails.root.join("config/queue.yml").read).result
    YAML.safe_load(config, aliases: true).fetch("production").fetch("workers")
  end
end
