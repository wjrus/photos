require "test_helper"

class QueueStatusControllerTest < ActionDispatch::IntegrationTest
  setup do
    OmniAuth.config.test_mode = true
    @owner = users(:one)
    sign_in_as(@owner)
  end

  teardown do
    OmniAuth.config.mock_auth[:google_oauth2] = nil
    OmniAuth.config.test_mode = false
  end

  test "owner can view queue status page" do
    get queue_status_path

    assert_response :success
    assert_includes response.body, "Queue status"
  end

  test "repository section links back to status overview" do
    get queue_status_path

    assert_response :success
    assert_includes response.body, repository_status_path
    assert_includes response.body, "Overview"
  end

  test "non owner cannot view queue status page" do
    delete sign_out_path
    sign_in_as(users(:two))

    get queue_status_path

    assert_redirected_to root_path
  end

  test "owner can clear failed queue executions" do
    snapshot = Struct.new(:clear_failures).new(3)
    original_build = QueueStatusSnapshot.method(:build)
    QueueStatusSnapshot.define_singleton_method(:build) { snapshot }

    delete queue_failures_path

    assert_redirected_to queue_status_path
    assert_equal "Cleared 3 failed jobs.", flash[:notice]
  ensure
    QueueStatusSnapshot.define_singleton_method(:build, original_build)
  end

  test "owner can retry pruned queue failures" do
    snapshot = Struct.new(:retry_pruned_failures).new(2)
    original_build = QueueStatusSnapshot.method(:build)
    QueueStatusSnapshot.define_singleton_method(:build) { snapshot }

    patch retry_pruned_queue_failures_path

    assert_redirected_to queue_status_path
    assert_equal "Retried 2 pruned jobs.", flash[:notice]
  ensure
    QueueStatusSnapshot.define_singleton_method(:build, original_build)
  end

  test "non owner cannot clear failed queue executions" do
    delete sign_out_path
    sign_in_as(users(:two))

    delete queue_failures_path

    assert_redirected_to root_path
  end

  test "non owner cannot retry pruned queue failures" do
    delete sign_out_path
    sign_in_as(users(:two))

    patch retry_pruned_queue_failures_path

    assert_redirected_to root_path
  end

  test "owner can resume paused queue executions" do
    snapshot = Struct.new(:resume_paused_queues).new(%w[archive maintenance])
    original_build = QueueStatusSnapshot.method(:build)
    QueueStatusSnapshot.define_singleton_method(:build) { snapshot }

    delete queue_pauses_path

    assert_redirected_to queue_status_path
    assert_equal "Resumed archive and maintenance.", flash[:notice]
  ensure
    QueueStatusSnapshot.define_singleton_method(:build, original_build)
  end

  test "non owner cannot resume paused queue executions" do
    delete sign_out_path
    sign_in_as(users(:two))

    delete queue_pauses_path

    assert_redirected_to root_path
  end

  private

  def sign_in_as(user)
    OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new(
      provider: user.provider,
      uid: user.uid,
      info: {
        email: user.email,
        name: user.name,
        image: user.avatar_url
      }
    )

    post "/auth/google_oauth2"
    follow_redirect!
  end
end
