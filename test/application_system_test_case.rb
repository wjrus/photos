require "test_helper"

class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  # Keep browser timing checks consistent as the suite grows past Rails' threshold.
  parallelize(workers: 1)

  driven_by :selenium, using: :headless_chrome, screen_size: [ 1400, 1400 ]
end
