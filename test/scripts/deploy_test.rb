require "test_helper"
require "open3"
require "tmpdir"

class DeployTest < ActiveSupport::TestCase
  test "deployment applies infrastructure and analysis image updates" do
    with_fake_deployment do |root, env|
      output, status = Open3.capture2e(env, "bash", root.join("scripts/deploy").to_s)

      assert status.success?, output
      calls = root.join("calls.log").read.lines.map(&:chomp)
      assert_includes calls, "compose pull db redis app_proxy"
      assert_includes calls, "compose up -d db redis"
      assert_operator calls.index("compose pull db redis app_proxy"), :<, calls.index("compose up -d db redis")
      assert_not calls.any? { |call| call.include?("--force-recreate") && call.match?(/\b(db|redis|app_proxy)\b/) }
      assert_includes calls, "compose build --pull analysis-local"
      assert_includes calls, "compose up -d --no-deps analysis-local"
      assert_includes calls, "compose up -d --no-deps app_proxy"
      assert_includes calls, "compose exec -T app_proxy nginx -t"
      assert_includes calls, "compose exec -T app_proxy nginx -s reload"
      assert_operator calls.index("compose exec -T app_proxy nginx -t"), :<, calls.index("compose stop web_blue")
      assert_includes calls, "image prune --force --filter label=com.docker.compose.project=photos --filter until=168h"
      assert_operator calls.index("compose up -d --no-deps worker --remove-orphans"), :<, calls.index("image prune --force --filter label=com.docker.compose.project=photos --filter until=168h")
      assert_includes calls, "system df"
      assert_not calls.any? { |call| call.match?(/(?:system|builder|buildx|volume|container) prune/) || call.include?("--all") || call.include?("--volumes") }
    end
  end

  test "invalid proxy configuration stops deployment before stopping the active backend" do
    with_fake_deployment do |root, env|
      output, status = Open3.capture2e(env.merge("PHOTOS_DEPLOY_TEST_INVALID_NGINX" => "1"), "bash", root.join("scripts/deploy").to_s)

      assert_not status.success?, output
      calls = root.join("calls.log").read.lines.map(&:chomp)
      assert_includes calls, "compose exec -T app_proxy nginx -t"
      assert_not_includes calls, "compose stop web_blue"
      assert_not_includes calls, "compose up -d --no-deps worker --remove-orphans"
      assert_not calls.any? { |call| call.include?("prune") }
    end
  end

  test "cleanup discovers custom project names and tolerates prune failures" do
    with_fake_deployment do |root, env|
      output, status = Open3.capture2e(env.merge("PHOTOS_DEPLOY_TEST_PROJECT" => "photos_custom", "PHOTOS_DEPLOY_TEST_PRUNE_FAILURE" => "1"), "bash", root.join("scripts/deploy").to_s)

      assert status.success?, output
      assert_includes output, "Photos image cleanup failed"
      assert_includes output, "Deploy complete."
      assert_includes root.join("calls.log").read, "image prune --force --filter label=com.docker.compose.project=photos_custom --filter until=168h"
    end
  end

  test "missing project labels skip cleanup rather than falling back to host-wide pruning" do
    with_fake_deployment do |root, env|
      output, status = Open3.capture2e(env.merge("PHOTOS_DEPLOY_TEST_PROJECT" => "<no value>"), "bash", root.join("scripts/deploy").to_s)

      assert status.success?, output
      assert_includes output, "image cleanup skipped"
      assert_not root.join("calls.log").read.include?("prune")
    end
  end

  test "image cleanup can be disabled for a deploy" do
    with_fake_deployment do |root, env|
      output, status = Open3.capture2e(env.merge("PHOTOS_DOCKER_CLEANUP" => "0"), "bash", root.join("scripts/deploy").to_s)

      assert status.success?, output
      assert_includes output, "cleanup disabled"
      assert_not root.join("calls.log").read.include?("prune")
      assert_includes root.join("calls.log").read, "system df"
    end
  end

  test "an unhealthy worker prevents cleanup" do
    with_fake_deployment do |root, env|
      output, status = Open3.capture2e(env.merge("PHOTOS_DEPLOY_TEST_WORKER_UNHEALTHY" => "1"), "bash", root.join("scripts/deploy").to_s)

      assert_not status.success?, output
      assert_includes output, "worker is unhealthy"
      assert_not root.join("calls.log").read.include?("prune")
    end
  end

  test "an invalid cleanup flag stops deployment before docker operations" do
    with_fake_deployment do |root, env|
      output, status = Open3.capture2e(env.merge("PHOTOS_DOCKER_CLEANUP" => "invalid"), "bash", root.join("scripts/deploy").to_s)

      assert_not status.success?, output
      assert_includes output, "PHOTOS_DOCKER_CLEANUP must be 0 or 1"
      assert_not root.join("calls.log").exist?
    end
  end

  private

  def with_fake_deployment
    Dir.mktmpdir("photos-deploy-test") do |directory|
      root = Pathname(directory)
      %w[scripts bin storage].each { |path| root.join(path).mkpath }
      FileUtils.cp(Rails.root.join("scripts/deploy"), root.join("scripts/deploy"))
      root.join(".env.production").write("PHOTOS_STORAGE_PATH=#{root.join('storage')}\nPHOTOS_HOST=photos.example.com\n")
      root.join(".env.postgres").write("")
      %w[git curl].each { |command| root.join("bin", command).write("#!/usr/bin/env bash\nexit 0\n") }
      root.join("bin/docker").write(<<~'BASH')
        #!/usr/bin/env bash
        set -eu
        printf '%s\n' "$*" >> "$PHOTOS_DEPLOY_TEST_ROOT/calls.log"
        if [[ "$*" == "compose ps -q "* ]]; then
          service="$4"
          if [[ "$service" == web_green && -f "$PHOTOS_DEPLOY_TEST_ROOT/green-recreated" ]]; then
            printf '%s\n' green-new
          else
            printf '%s-old\n' "$service"
          fi
        elif [[ "$1" == inspect ]]; then
          if [[ "$3" == *'.Mounts'* ]]; then
            printf '%s/storage\n' "$PHOTOS_DEPLOY_TEST_ROOT"
          elif [[ "$3" == *'.Config.Labels'* ]]; then
            printf '%s\n' "${PHOTOS_DEPLOY_TEST_PROJECT:-photos}"
          elif [[ "$*" == *worker-old ]]; then
            if [[ "${PHOTOS_DEPLOY_TEST_WORKER_UNHEALTHY:-0}" == 1 ]]; then
              printf '%s\n' unhealthy
            else
              printf '%s\n' running
            fi
          else
            printf '%s\n' healthy
          fi
        elif [[ "$*" == "compose up -d --no-deps --force-recreate web_green" ]]; then
          touch "$PHOTOS_DEPLOY_TEST_ROOT/green-recreated"
        elif [[ "$*" == "compose exec -T app_proxy nginx -t" && "${PHOTOS_DEPLOY_TEST_INVALID_NGINX:-0}" == 1 ]]; then
          exit 1
        elif [[ "$1 $2" == "image prune" && "${PHOTOS_DEPLOY_TEST_PRUNE_FAILURE:-0}" == 1 ]]; then
          exit 1
        fi
      BASH
      root.join("bin").children.each { |path| path.chmod(0o755) }
      yield root, {
        "PATH" => "#{root.join('bin')}:/usr/bin:/bin",
        "PHOTOS_DEPLOY_TEST_ROOT" => root.to_s,
        "COMPOSE_PROFILES" => nil,
        "PHOTOS_DOCKER_CLEANUP" => nil,
        "PHOTOS_DEPLOY_TEST_PROJECT" => nil,
        "PHOTOS_DEPLOY_TEST_PRUNE_FAILURE" => nil,
        "PHOTOS_DEPLOY_TEST_WORKER_UNHEALTHY" => nil
      }
    end
  end
end
