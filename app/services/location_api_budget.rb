# A resumable, conservative spending ceiling for an explicitly requested repair.
# Cached responses never reach this hook; failed HTTP attempts still count.
class LocationApiBudget
  class Exceeded < StandardError; end
  PRICES = { geocoding: 5_000, places_nearby: 32_000 }.freeze # millionths of USD
  SETTING_KEY = "native_location_repair_budget_v1".freeze

  def self.with_repair_limit(cents:)
    previous = Thread.current[:location_api_budget]
    Thread.current[:location_api_budget] = new(cents: cents)
    yield
  ensure
    Thread.current[:location_api_budget] = previous
  end

  def self.reserve!(kind)
    Thread.current[:location_api_budget]&.reserve!(kind)
  end

  def initialize(cents:)
    limit = Integer(cents) * 10_000
    raise ArgumentError, "Repair budget must be between $0.01 and $50" unless (10_000..50_000_000).cover?(limit)

    now = Time.current
    AppSetting.insert_all([ { key: SETTING_KEY, value: { limit: limit, reserved: 0, requests: {} }.to_json, created_at: now, updated_at: now } ], unique_by: :key)
    @setting = AppSetting.find_by!(key: SETTING_KEY)
    @limit = limit
  end

  def reserve!(kind)
    delay = 0
    @setting.with_lock do
      data = JSON.parse(@setting.value)
      limit = [ Integer(data.fetch("limit")), @limit ].min
      reserved = Integer(data.fetch("reserved")) + PRICES.fetch(kind)
      raise Exceeded, "Location repair reached its API spending ceiling" if reserved > limit

      now = Time.current.to_f
      next_at = [ now, data.fetch("next_at", 0).to_f ].max
      delay = next_at - now
      data["next_at"] = next_at + 1
      data["reserved"] = reserved
      data.fetch("requests")[kind.to_s] = data.fetch("requests").fetch(kind.to_s, 0) + 1
      @setting.update!(value: data.to_json)
    end
    sleep(delay) if delay.positive?
  end

  def self.status
    value = AppSetting.find_by(key: SETTING_KEY)&.value
    value ? JSON.parse(value).except("next_at") : { "reserved" => 0, "requests" => {} }
  end
end
