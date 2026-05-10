require "test_helper"

class QueueConfigTest < ActiveSupport::TestCase
  test "workers include Solid Queue recurring jobs" do
    config = ERB.new(Rails.root.join("config/queue.yml").read).result
    workers = YAML.safe_load(config, aliases: true).fetch("production").fetch("workers")

    assert_includes workers.map { |worker| worker.fetch("queues") }, "solid_queue_recurring"
  end
end
