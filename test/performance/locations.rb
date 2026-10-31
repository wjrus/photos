# Run with: RAILS_ENV=test rbenv exec bundle exec rails runner test/performance/locations.rb
# Only synthetic records, rolled back afterward. No media files or geocoding calls.
abort "Run this benchmark only in the test environment" unless Rails.env.test?

module LocationsBenchmark
  def self.seed
    now = Time.current
    token = SecureRandom.hex(8)
    owner = User.create!(provider: "password", uid: token, email: "#{token}@example.invalid", role: "owner", password: "synthetic-password12")
    places = PhotoPlace.insert_all!(1_000.times.map do |index|
      town = format("Synthetic town %03d", index % 100)
      raw = { address_components: [
        { long_name: town, types: [ "locality" ] },
        { long_name: "Synthetic County", types: [ "administrative_area_level_2" ] },
        { long_name: "Synthetic State", types: [ "administrative_area_level_1" ] },
        { long_name: "United States", short_name: "US", types: [ "country" ] }
      ], synthetic_payload: "x" * 2_000 }
      region = LocationMapRegion.for_result(raw)
      { identity_key: "benchmark:#{token}:#{index}", name: "Synthetic venue #{index}", place_type: "premise", raw: raw,
        map_region_key: (region[:map_region_key] unless index % 4 == 0),
        map_region_name: (town unless index % 4 == 0), created_at: now, updated_at: now }
    end).rows.flatten
    10.times do |batch|
      ids = Photo.insert_all!(10_000.times.map do |index|
        { owner_id: owner.id, title: "Synthetic photo", content_type: "image/jpeg", original_filename: "synthetic.jpg",
          captured_at: Time.utc(2020, 1, 1) + (batch * 10_000 + index).hours, created_at: now, updated_at: now }
      end).rows.flatten
      PhotoMetadata.insert_all!(ids.each_with_index.map do |id, index|
        { photo_id: id, photo_place_id: places[index % places.size], latitude: 40 + (index % 100) * 0.001, longitude: -80,
          width: 4032, height: 3024, extraction_status: "complete", created_at: now, updated_at: now }
      end)
    end
    owner
  end

  def self.measure
    queries = []
    records = Hash.new(0)
    sql = ->(event) { queries << [ event.duration, event.payload[:name], event.payload[:sql] ] unless event.payload[:name] == "SCHEMA" || event.payload[:cached] }
    instantiate = ->(event) { records[event.payload[:class_name]] += event.payload[:record_count] }
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = nil
    ActiveSupport::Notifications.subscribed(sql, "sql.active_record") do
      ActiveSupport::Notifications.subscribed(instantiate, "instantiation.active_record") { result = yield }
    end
    { milliseconds: ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1_000).round(2),
      sql_ms: queries.sum(&:first).round(2), queries: queries.size, records: records,
      slow_queries: queries.sort_by(&:first).reverse.first(5).map { |duration, name, statement| { ms: duration.round(2), name: name, area_json: statement.include?("location_area_components") } },
      result: result }
  end

  def self.plan_nodes(node)
    [ node, *Array(node["Plans"]).flat_map { |child| plan_nodes(child) } ]
  end
end

ActiveRecord::Base.transaction do
  owner = LocationsBenchmark.seed
  scope = Photo.visible_to(owner).where(owner_id: owner.id).joins(:metadata).merge(PhotoMetadata.geotagged)
  area_id = PhotoLocationArea.id_for_region(LocationMapRegion.for_result({ address_components: [
    { long_name: "Synthetic town 000", types: [ "locality" ] },
    { long_name: "Synthetic County", types: [ "administrative_area_level_2" ] },
    { long_name: "Synthetic State", types: [ "administrative_area_level_1" ] },
    { long_name: "United States", short_name: "US", types: [ "country" ] }
  ] }).fetch(:map_region_key))
  connection = ActiveRecord::Base.connection
  %w[photos photo_metadata photo_places].each { |table| connection.execute("ANALYZE #{table}") }
  session = ActionDispatch::Integration::Session.new(Rails.application)
  session.post("/sign_in", params: { email: owner.email, password: "synthetic-password12" })
  abort "Synthetic sign-in failed" unless session.response.redirect?
  original_cache = Rails.cache
  Rails.cache = ActiveSupport::Cache::MemoryStore.new
  results = ActiveRecord::Base.uncached do
    {
      directory: LocationsBenchmark.measure { PhotoLocationArea.groups(scope, limit: 501, sort: "geography").size },
      directory_count: LocationsBenchmark.measure { PhotoLocationArea.group_count(scope) },
      detail_count: LocationsBenchmark.measure { PhotoLocationArea.scope_for(scope, area_id).count },
      index_cold: LocationsBenchmark.measure { session.get("/locations"); session.response.status },
      index_warm: LocationsBenchmark.measure { session.get("/locations"); session.response.status },
      detail_cold: LocationsBenchmark.measure { session.get("/locations/#{area_id}"); session.response.status },
      detail_warm: LocationsBenchmark.measure { session.get("/locations/#{area_id}"); session.response.status }
    }
  end
  raise "Unexpected synthetic location count" unless results[:directory][:result] == 100
  raise "Unexpected synthetic directory count" unless results[:directory_count][:result] == 100
  raise "Unexpected synthetic town membership" unless results[:detail_count][:result] == 1_000
  results.each do |name, result|
    next unless name.to_s.start_with?("index_", "detail_cold", "detail_warm")

    raise "Request failed: #{name}" unless result[:result] == 200
  end
  members = PhotoLocationArea.scope_for(scope, area_id)
  page_query = Photo.from(members.offset(0), :photos).reselect("photos.id").chronological_order.limit(61)
  plan = JSON.parse(connection.select_value("EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) #{page_query.to_sql}")).first
  results[:detail_page_plan] = {
    execution_ms: plan.fetch("Execution Time"),
    nodes: LocationsBenchmark.plan_nodes(plan.fetch("Plan")).map do |node|
      node.slice("Node Type", "Relation Name", "Index Name", "Actual Rows", "Actual Loops", "Rows Removed by Filter")
    end
  }
  puts JSON.pretty_generate(results)
  raise ActiveRecord::Rollback
ensure
  Rails.cache = original_cache if original_cache
end
