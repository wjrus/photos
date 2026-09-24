require "test_helper"
require "active_record/testing/query_assertions"

class PhotoSearchOrderSnapshotTest < ActiveSupport::TestCase
  include ActiveRecord::Assertions::QueryAssertions

  setup do
    @previous_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    @owner = users(:one)
    now = Time.current
    @ids = Photo.insert_all!(3.times.map do |index|
      { owner_id: @owner.id, title: "Snapshot #{index}", visibility: "private", created_at: now + index.seconds, updated_at: now }
    end).rows.flatten
    @scope = Photo.visible_to(@owner).stream_order
  end

  teardown do
    Rails.cache = @previous_cache
  end

  test "snapshots load only ordered ids without instantiating photos or attachments" do
    instantiated = 0
    subscriber = ->(event) { instantiated += event.payload[:record_count] }
    token = nil

    ActiveSupport::Notifications.subscribed(subscriber, "instantiation.active_record") do
      assert_queries_count(1) do
        token = PhotoSearchOrderSnapshot.store(scope: @scope.with_original_variant_records, user: @owner)
      end
    end

    assert_equal 0, instantiated
    assert_equal({ previous_id: @ids.last, next_id: @ids.first }, neighbors(token, @ids.second))
  end

  test "subsequent pages reuse the snapshot without querying photos" do
    token = PhotoSearchOrderSnapshot.store(scope: @scope, user: @owner)

    assert_no_queries do
      assert_equal token, PhotoSearchOrderSnapshot.store(scope: @scope, user: @owner, token: token)
    end
    assert_equal({ previous_id: nil, next_id: @ids.second }, neighbors(token, @ids.last))
  end

  test "a changed search cannot reuse a different query's snapshot" do
    token = PhotoSearchOrderSnapshot.store(scope: @scope, user: @owner)

    assert_queries_count(1) do
      PhotoSearchOrderSnapshot.store(scope: @scope.where(id: @ids.first), user: @owner, token: token)
    end
    assert_nil neighbors(token, @ids.second)
    assert_equal({ previous_id: nil, next_id: nil }, neighbors(token, @ids.first))
  end

  test "expired snapshots rebuild from the current results" do
    token = PhotoSearchOrderSnapshot.store(scope: @scope, user: @owner)
    Photo.where(id: @ids.second).delete_all

    travel PhotoSearchOrderSnapshot::TTL + 1.second do
      assert_queries_count(1) do
        PhotoSearchOrderSnapshot.store(scope: @scope, user: @owner, token: token)
      end
    end
    assert_equal({ previous_id: @ids.last, next_id: nil }, neighbors(token, @ids.first))
  end

  test "tokens cannot read or overwrite another audience's snapshot" do
    token = PhotoSearchOrderSnapshot.store(scope: @scope, user: @owner)
    Photo.where(id: @ids.first).update_all(visibility: "public")

    assert_nil neighbors(token, @ids.second, user: nil)
    PhotoSearchOrderSnapshot.store(scope: Photo.visible_to(nil).stream_order, user: nil, token: token)

    assert_equal({ previous_id: nil, next_id: nil }, neighbors(token, @ids.first, user: nil))
    assert_equal({ previous_id: @ids.last, next_id: @ids.first }, neighbors(token, @ids.second))
  end

  test "an empty search has no snapshot" do
    assert_nil PhotoSearchOrderSnapshot.store(scope: @scope.none, user: @owner)
  end

  test "snapshots remain bounded to the first ten thousand matches" do
    now = Time.current
    Photo.insert_all!((PhotoSearchOrderSnapshot::MAX_IDS - @ids.size + 1).times.map do |index|
      { owner_id: @owner.id, title: "Bulk snapshot #{index}", visibility: "private", created_at: now + 1.day, updated_at: now }
    end)

    token = PhotoSearchOrderSnapshot.store(scope: @scope, user: @owner)

    assert_nil neighbors(token, @ids.first)
    assert_equal({ previous_id: @ids.last, next_id: nil }, neighbors(token, @ids.second))
  end

  private

  def neighbors(token, photo_id, user: @owner)
    PhotoSearchOrderSnapshot.neighbor_ids(token: token, user: user, photo_id: photo_id)
  end
end
