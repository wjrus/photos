require "test_helper"

class RepositoryHealthControllerTest < ActionDispatch::IntegrationTest
  setup do
    OmniAuth.config.test_mode = true
    @owner = users(:one)
    sign_in_as(@owner)
  end

  teardown do
    OmniAuth.config.mock_auth[:google_oauth2] = nil
    OmniAuth.config.test_mode = false
  end

  test "owner can view repository health page" do
    get repository_health_path

    assert_response :success
    assert_includes response.body, "Repository health"
    assert_includes response.body, "Queue baseline scan"
    assert_includes response.body, "Showing latest"
    assert_includes response.body, "Health jobs"
  end

  test "repository section links back to status overview" do
    get repository_health_path

    assert_response :success
    assert_includes response.body, repository_status_path
    assert_includes response.body, "Overview"
  end

  test "non owner cannot view repository health page" do
    delete sign_out_path
    sign_in_as(users(:two))

    get repository_health_path

    assert_redirected_to root_path
  end

  test "owner can queue patrol" do
    assert_enqueued_with(job: OriginalFileHealthPatrolJob) do
      post repository_health_path
    end

    assert_redirected_to repository_health_path
    assert_equal "Repository patrol queued.", flash[:notice]
  end

  test "owner can queue baseline scan" do
    assert_enqueued_with(job: OriginalFileHealthPatrolJob) do
      post repository_health_path, params: { scan_type: "baseline" }
    end

    assert_redirected_to repository_health_path
    assert_equal "Baseline repository scan queued.", flash[:notice]
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
