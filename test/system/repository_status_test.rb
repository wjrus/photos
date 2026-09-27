require "application_system_test_case"

class RepositoryStatusTest < ApplicationSystemTestCase
  setup do
    @owner = users(:one)
    @owner.update!(name: "Repository Owner", email: "repository-owner@example.com", password: "password12")
    visit sign_in_path
    fill_in "Email", with: @owner.email
    fill_in "Password", with: "password12"
    click_button "Sign in"
    assert_current_path root_path
  end

  test "the page shell appears before its independent panels finish loading" do
    visit_dashboard(mode: "hold")

    assert_selector "h1", text: "Repository status"
    assert_selector "[data-controller~='repository-panel']", count: 3
    assert_selector "#{panel_selector('library')} [data-repository-panel-target='status']", text: "Loading"
    assert_no_selector "[data-panel-sample]"
    wait_for_requests("library", 1)
    assert_empty requested_panels - %w[library queues activity]

    page.execute_script("repositoryPanelRequests.find(request => request.panel === 'library').release()")
    assert_selector "#{panel_selector('library')} [data-panel-sample]", text: "library sample 1"
    assert_current_path repository_status_path(section: "overview")
  end

  test "queue updates leave slower panels and the page document alone" do
    visit_dashboard
    assert_selector "#{panel_selector('library')} [data-panel-sample]"
    scroll_to_panel("queues")
    assert_selector "#{panel_selector('queues')} [data-panel-sample]"
    page.execute_script("window.repositoryPageDocument = document; window.repositoryPanelVersion = 2")
    counts = request_counts

    refresh_panel("queues")

    assert_selector "#{panel_selector('queues')} [data-panel-sample]", text: "queues sample 2"
    assert_equal counts.fetch("queues") + 1, request_counts.fetch("queues")
    assert_equal counts.fetch("library"), request_counts.fetch("library")
    assert page.evaluate_script("repositoryPageDocument === document")
    assert_not page.evaluate_script("repositoryPanelRequests.at(-1).url.searchParams.has('refresh')")
  end

  test "unchanged data keeps focused inputs and expanded details in the same DOM" do
    visit_dashboard(section: "queues")
    assert_selector "[data-panel-sample]", text: "queues sample 1"
    find("summary", text: "Diagnostics").click
    fill_in "Synthetic batch size", with: "37"
    page.execute_script("window.repositoryOriginalInput = document.querySelector('[data-panel-input]')")
    count = request_counts.fetch("queues")

    refresh_panel("queues")
    wait_for_requests("queues", count + 1)
    assert_selector "[data-repository-panel-target='content'][aria-busy='false']"

    assert page.evaluate_script("repositoryOriginalInput === document.querySelector('[data-panel-input]')")
    assert page.evaluate_script("document.activeElement === repositoryOriginalInput")
    assert_field "Synthetic batch size", with: "37"
    assert_selector "details[open]"
    assert_selector "[data-repository-panel-target='status']", text: "Last updated"
    assert_no_selector "[data-repository-panel-target='status']", text: "Update ready"
  end

  test "new data waits for edits and a deliberate refresh can replace it" do
    visit_dashboard(section: "queues")
    assert_selector "[data-panel-sample]", text: "queues sample 1"
    fill_in "Synthetic batch size", with: "37"
    page.execute_script("window.repositoryPanelVersion = 2")

    refresh_panel("queues")

    assert_selector "[data-repository-panel-target='status']", text: "Update ready"
    assert_field "Synthetic batch size", with: "37"
    assert_selector "[data-panel-sample]", text: "queues sample 1"
    find("[data-action~='repository-panel#refresh']").click

    assert_selector "[data-panel-sample]", text: "queues sample 2"
    assert_field "Synthetic batch size", with: "10"
    assert page.evaluate_script("repositoryPanelRequests.at(-1).url.searchParams.get('refresh') === '1'")
  end

  test "a failed update preserves the last result and can recover without reloading" do
    visit_dashboard(section: "queues")
    assert_selector "[data-panel-sample]", text: "queues sample 1"
    updated = find("[data-repository-panel-target='status']").text
    page.execute_script("window.repositoryPanelMode = 'error'")

    refresh_panel("queues")

    assert_selector "[data-repository-panel-target='status']", text: "Update failed"
    assert_selector "[data-repository-panel-target='status']", text: updated
    assert_selector "[data-panel-sample]", text: "queues sample 1"
    assert_operator page.evaluate_script("#{controller_script('queues')}.nextRefreshAt - Date.now()"), :>, 15_000
    refresh_panel("queues", manual: true)
    wait_for_condition("#{controller_script('queues')}.failures === 2")
    assert_operator page.evaluate_script("#{controller_script('queues')}.nextRefreshAt - Date.now()"), :>, 35_000
    page.execute_script("window.repositoryPanelMode = 'success'; window.repositoryPanelVersion = 2")
    find("[data-action~='repository-panel#refresh']").click

    assert_selector "[data-panel-sample]", text: "queues sample 2"
    assert_no_selector "[data-repository-panel-target='status']", text: "failed"
  end

  test "a manual refresh never overwrites edits begun while its response is pending" do
    visit_dashboard(section: "queues")
    assert_selector "[data-panel-sample]", text: "queues sample 1"
    page.execute_script("window.repositoryPanelMode = 'hold'; window.repositoryPanelVersion = 2")
    find("[data-action~='repository-panel#refresh']").click
    wait_for_requests("queues", 2)
    fill_in "Synthetic batch size", with: "41"

    page.execute_script("repositoryPanelRequests.at(-1).release()")

    assert_selector "[data-repository-panel-target='status']", text: "Update ready"
    assert_field "Synthetic batch size", with: "41"
    assert_selector "[data-panel-sample]", text: "queues sample 1"
  end

  test "hidden tabs pause updates and pending requests never overlap or survive navigation" do
    visit_dashboard(section: "queues")
    assert_selector "[data-panel-sample]", text: "queues sample 1"
    page.execute_script <<~JS
      Object.defineProperty(document, 'hidden', { configurable: true, value: true })
      document.dispatchEvent(new Event('visibilitychange'))
      window.repositoryPanelMode = 'hold'
    JS
    refresh_panel("queues")
    settle_browser
    assert_equal 1, request_counts.fetch("queues")

    page.execute_script <<~JS
      delete document.hidden
      document.dispatchEvent(new Event('visibilitychange'))
    JS
    wait_for_requests("queues", 2)
    3.times { refresh_panel("queues", manual: true) }
    settle_browser
    assert_equal 2, request_counts.fetch("queues")
    page.execute_script("Turbo.visit('/')")

    assert_current_path root_path
    assert page.evaluate_script("repositoryPanelRequests.at(-1).aborted")
  ensure
    page.execute_script("delete document.hidden")
  end

  test "offscreen panels wait until visible before catching up" do
    visit_dashboard(section: "queues")
    assert_selector "[data-panel-sample]", text: "queues sample 1"
    page.execute_script("document.querySelector('[data-controller~=repository-panel]').style.marginTop = '3000px'; window.scrollTo(0, 0)")
    wait_for_condition("!#{controller_script('queues')}.visible")
    refresh_panel("queues")
    settle_browser
    assert_equal 1, request_counts.fetch("queues")

    scroll_to_panel("queues")

    wait_for_requests("queues", 2)
  end

  test "non JSON and expired access responses never replace trusted panel content" do
    visit_dashboard(section: "queues")
    assert_selector "[data-panel-sample]", text: "queues sample 1"
    page.execute_script("window.repositoryPanelMode = 'html'")
    refresh_panel("queues")
    assert_selector "[data-repository-panel-target='status']", text: "Update failed"
    assert_no_selector "[data-untrusted-login]"
    assert_selector "[data-panel-sample]", text: "queues sample 1"

    page.execute_script("window.repositoryPanelMode = 'forbidden'")
    refresh_panel("queues", manual: true)
    assert_selector "[data-repository-panel-target='status']", text: "Access expired"
    count = request_counts.fetch("queues")
    refresh_panel("queues")
    settle_browser

    assert_equal count, request_counts.fetch("queues")
    assert_no_selector "[data-panel-sample]"
  end

  test "real panels load at desktop and narrow mobile widths without overflowing" do
    browser = page.driver.browser
    %w[overview files analysis queues].each do |section|
      visit_dashboard(section: section, mode: "real")
      all("[data-controller~='repository-panel']", minimum: 1).each do |panel|
        page.execute_script("arguments[0].scrollIntoView({ block: 'start' })", panel)
        within(panel) { assert_selector "[data-repository-panel-target='status']", text: "Last updated" }
      end
      assert_no_horizontal_overflow
      page.execute_script("window.scrollTo(0, 0)")
      page.save_screenshot(Rails.root.join("tmp/screenshots/repository-#{section}-desktop.png"))

      browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: 390, height: 844, deviceScaleFactor: 1, mobile: true)
      assert_no_horizontal_overflow
      page.save_screenshot(Rails.root.join("tmp/screenshots/repository-#{section}-390.png"))
      browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
    end
  ensure
    browser&.execute_cdp("Emulation.clearDeviceMetricsOverride")
  end

  test "populated queue controls and their confirmation survive updates on a narrow screen" do
    previous_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    data = synthetic_queue_data
    cache_queue_snapshot(data)
    visit_dashboard(section: "queues", mode: "real")
    assert_selector "[data-repository-panel-target='status']", text: "Last updated"
    assert_selector "button[aria-label='Resume analysis']"
    assert_selector "input[name='queue_name']", count: 4, visible: :all
    assert_no_horizontal_overflow
    page.save_screenshot(Rails.root.join("tmp/screenshots/repository-queues-active-desktop.png"))

    browser = page.driver.browser
    browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: 390, height: 844, deviceScaleFactor: 1, mobile: true)
    assert_no_horizontal_overflow
    page.save_screenshot(Rails.root.join("tmp/screenshots/repository-queues-active-390.png"))
    page.execute_script("document.querySelector('table[aria-label=\"Queue status and controls\"] tbody tr').scrollIntoView({ block: 'start' })")
    page.save_screenshot(Rails.root.join("tmp/screenshots/repository-queue-controls-390.png"))
    find("#queue-failures summary").click
    click_button "Clear failed jobs"
    assert_selector "[role='dialog']", text: "Clear failed jobs?"
    page.execute_script("window.repositoryQueueModal = document.querySelector('[role=dialog]:not(.hidden)')")
    data[:queue_totals][:ready] += 1
    data[:controls][:queues].first[:counts][:ready] += 1
    data[:controls][:queues].first[:ready] += 1
    data[:controls][:queues].first[:total] += 1
    data[:job_classes].first[:total] += 1
    cache_queue_snapshot(data)

    refresh_panel("queues")

    wait_for_condition("#{controller_script('queues')}.statusTarget.textContent.includes('Update ready')")
    assert page.evaluate_script("repositoryQueueModal.isConnected && !repositoryQueueModal.classList.contains('hidden')")
    assert_no_horizontal_overflow
    page.save_screenshot(Rails.root.join("tmp/screenshots/repository-queues-dialog-390.png"))
    within("[role='dialog']") { click_button "Cancel" }
    assert_no_selector "[role='dialog']"
    assert_selector "#queue-failures[open]"
    assert page.evaluate_script("document.activeElement.textContent.trim() === 'Clear failed jobs'")
    find("#queue-failures summary").click
    find("h1").click
    wait_for_condition("#{controller_script('queues')}.lastVersion === #{Digest::SHA256.hexdigest(data.to_json).to_json}")
    assert_selector "[data-repository-panel-target='status']", text: "Last updated"
  ensure
    browser&.execute_cdp("Emulation.clearDeviceMetricsOverride")
    Rails.cache = previous_cache if previous_cache
  end

  private

  def visit_dashboard(section: "overview", mode: "success")
    page.execute_script <<~JS, mode
      window.repositoryPanelRequests = []
      window.repositoryPanelMode = arguments[0]
      window.repositoryPanelVersion = 1
      const originalFetch = window.repositoryOriginalFetch || window.fetch.bind(window)
      window.repositoryOriginalFetch = originalFetch
      window.fetch = (input, options = {}) => {
        const url = new URL(input, window.location.href)
        if (!url.pathname.startsWith('/repository_status/panels/')) return originalFetch(input, options)
        const request = { url, panel: url.pathname.split('/').at(-1), aborted: false }
        repositoryPanelRequests.push(request)
        const payload = () => new Response(JSON.stringify({
          html: `<p data-panel-sample>${request.panel} sample ${repositoryPanelVersion}</p><input type="hidden" value="${repositoryPanelRequests.length}"><details><summary>Diagnostics</summary><p>Preserve expanded details</p></details><label>Synthetic batch size<input data-panel-input value="10"></label>`,
          version: String(repositoryPanelVersion),
          generated_at: new Date(Date.now() + repositoryPanelVersion * 1000).toISOString(),
          refresh_after: 120
        }), { headers: { 'Content-Type': 'application/json' } })
        if (repositoryPanelMode === 'real') return originalFetch(input, options)
        if (repositoryPanelMode === 'error') return Promise.reject(new TypeError('Synthetic network failure'))
        if (repositoryPanelMode === 'html') return Promise.resolve(new Response('<form data-untrusted-login>Sign in</form>', { headers: { 'Content-Type': 'text/html' } }))
        if (repositoryPanelMode === 'forbidden') return Promise.resolve(new Response('{}', { status: 403, headers: { 'Content-Type': 'application/json' } }))
        if (repositoryPanelMode !== 'hold') return Promise.resolve(payload())
        return new Promise((resolve, reject) => {
          request.release = () => resolve(payload())
          options.signal.addEventListener('abort', () => {
            request.aborted = true
            reject(new DOMException('Aborted', 'AbortError'))
          })
        })
      }
    JS
    page.execute_script("Turbo.visit(arguments[0])", repository_status_path(section: section))
    assert_selector "h1", text: "Repository status"
    assert_selector "nav[aria-label='Repository status sections'] a[aria-current='page'][href='#{repository_status_path(section: section)}']"
  end

  def panel_selector(panel)
    "[data-repository-panel-url-value*='/panels/#{panel}']"
  end

  def controller_script(panel)
    "Stimulus.getControllerForElementAndIdentifier(document.querySelector(#{panel_selector(panel).to_json}), 'repository-panel')"
  end

  def scroll_to_panel(panel)
    page.execute_script("document.querySelector(arguments[0]).scrollIntoView({ block: 'start' })", panel_selector(panel))
  end

  def refresh_panel(panel, manual: false)
    page.execute_script <<~JS
      const controller = #{controller_script(panel)}
      #{manual ? 'controller.refresh()' : 'controller.nextRefreshAt = 0; controller.visibilityChanged()'}
    JS
  end

  def requested_panels
    page.evaluate_script("repositoryPanelRequests.map(request => request.panel)")
  end

  def request_counts
    requested_panels.tally
  end

  def wait_for_requests(panel, count)
    wait_for_condition("repositoryPanelRequests.filter(request => request.panel === #{panel.to_json}).length >= #{count}")
  end

  def wait_for_condition(script)
    page.document.synchronize(5) do
      raise Capybara::ExpectationNotMet, "Repository panel did not reach its expected state" unless page.evaluate_script(script)
    end
  end

  def settle_browser
    page.evaluate_async_script("const done = arguments[0]; setTimeout(done, 75)")
  end

  def assert_no_horizontal_overflow
    assert page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth"), "Repository status overflows the viewport"
  end

  def cache_queue_snapshot(data)
    Rails.cache.write(RepositoryStatusData.cache_key(@owner.id, "queues"), { data: data, generated_at: Time.current })
  end

  def synthetic_queue_data
    queues = %w[analysis archive import derivatives].each_with_index.map do |name, index|
      counts = { ready: index.zero? ? 12 : index, claimed: 2, scheduled: 4, failed: index.zero? ? 1 : 0, blocked: 0 }
      { name: name, paused: index.zero?, ready: counts[:ready], claimed: counts[:claimed], total: counts.values.sum, counts: counts, managed: true }
    end
    {
      snapshot_available: true,
      queue_totals: QueueStatusSnapshot::EXECUTION_STATES.keys.to_h { |state| [ state, queues.sum { |queue| queue[:counts][state] } ] },
      queues: queues, controls: { queues: queues }, pauses: [ { "queue_name" => "analysis" } ],
      finished_counts: { last_hour: 38, last_day: 520 }, pruned_failure_count: 1,
      job_classes: [ { name: "SyntheticRepositoryAnalysisJob", counts: queues.first[:counts], total: queues.first[:total] } ],
      recent_failures: [ { "class_name" => "SyntheticRepositoryAnalysisJob", "queue_name" => "analysis", "error" => "Synthetic provider returned an unavailable response while analyzing a sample photo.", "failed_at" => Time.current } ],
      processes: [ { "name" => "synthetic-worker-01", "kind" => "Worker", "pid" => 1234, "hostname" => "queue.example.org", "last_heartbeat_at" => Time.current } ]
    }
  end
end
