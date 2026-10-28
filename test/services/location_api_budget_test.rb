require "test_helper"

class LocationApiBudgetTest < ActiveSupport::TestCase
  test "repair spending resumes across instances and stops before the next request exceeds its ceiling" do
    LocationApiBudget.with_repair_limit(cents: 1) { LocationApiBudget.reserve!(:geocoding) }
    travel 2.seconds do
      LocationApiBudget.with_repair_limit(cents: 1) { LocationApiBudget.reserve!(:geocoding) }
    end
    assert_equal 10_000, LocationApiBudget.status.fetch("reserved")
    assert_raises(LocationApiBudget::Exceeded) do
      LocationApiBudget.with_repair_limit(cents: 1) { LocationApiBudget.reserve!(:geocoding) }
    end
    assert_equal({ "geocoding" => 2 }, LocationApiBudget.status.fetch("requests"))
    assert_equal 10_000, LocationApiBudget.status.fetch("reserved")
    LocationApiBudget.reserve!(:places_nearby)
    assert_equal 10_000, LocationApiBudget.status.fetch("reserved"), "Ordinary unrelated requests do not consume the delegated repair budget"
  end

  test "repair authorization cannot exceed fifty dollars or reset already reserved charges" do
    assert_raises(ArgumentError) { LocationApiBudget.new(cents: 5_001) }
    LocationApiBudget.with_repair_limit(cents: 4) { LocationApiBudget.reserve!(:places_nearby) }
    assert_equal 32_000, LocationApiBudget.status.fetch("reserved")
    assert_raises(LocationApiBudget::Exceeded) do
      LocationApiBudget.with_repair_limit(cents: 4) { LocationApiBudget.reserve!(:places_nearby) }
    end
  end
end
