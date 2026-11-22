require "test_helper"
require "open3"
require "tmpdir"

class DeployTest < ActiveSupport::TestCase
  test "normal deployment leaves singleton infrastructure running and confirms the new backend" do
    with_fake_deployment do |root, env|
      output, status = Open3.capture2e(env, "bash", root.join("scripts/deploy").to_s)

      assert status.success?, output
      calls = root.join("calls.log").read.lines.map(&:chomp)
      assert_not_includes calls, "compose pull db redis app_proxy"
      assert_includes calls, "compose up -d --no-recreate db redis"
      assert_not calls.any? { |call| call.include?("--force-recreate") && call.match?(/\b(db|redis|app_proxy)\b/) }
      assert_includes calls, "compose build --pull analysis-local"
      assert_includes calls, "compose up -d --no-deps analysis-local"
      assert_not calls.any? { |call| call.start_with?("compose up ") && call.end_with?(" app_proxy") }
      assert_includes calls, "compose exec -T app_proxy nginx -t"
      assert_includes calls, "compose exec -T app_proxy nginx -s reload"
      assert_operator calls.index("compose exec -T app_proxy nginx -t"), :<, calls.index("compose stop web_blue")
      assert_operator calls.index("probe web_green"), :<, calls.index("compose stop web_blue")
      assert_operator calls.index("proxy workers 21 22"), :<, calls.index("compose stop web_blue")
      assert_includes calls, "image prune --force --filter label=com.docker.compose.project=photos --filter until=168h"
      assert_operator calls.index("compose up -d --no-deps worker --remove-orphans"), :<, calls.index("image prune --force --filter label=com.docker.compose.project=photos --filter until=168h")
      assert_includes calls, "system df"
      assert_not calls.any? { |call| call.match?(/(?:system|builder|buildx|volume|container) prune/) || call.include?("--all") || call.include?("--volumes") }
    end
  end

  test "maintenance deployment applies updates to singleton infrastructure" do
    with_fake_deployment do |root, env|
      output, status = Open3.capture2e(env.merge("PHOTOS_UPDATE_INFRASTRUCTURE" => "1"), "bash", root.join("scripts/deploy").to_s)

      assert status.success?, output
      calls = root.join("calls.log").read.lines.map(&:chomp)
      assert_includes calls, "compose pull db redis app_proxy"
      assert_includes calls, "compose up -d db redis"
      assert_operator calls.index("compose pull db redis app_proxy"), :<, calls.index("compose up -d db redis")
      assert_includes calls, "compose run --rm --no-deps app_proxy nginx -t"
      assert_includes calls, "compose up -d --no-deps --force-recreate app_proxy"
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
      assert_equal "upstream photos_app { server web_blue:80; }\n", root.join("tmp/nginx/active_upstream.conf").read
      assert_includes output, "the previous app_proxy upstream was restored"
    end
  end

  test "old backend 200 after reload cannot complete cutover and rolls back to a legacy backend" do
    with_fake_deployment do |root, env|
      output, status = Open3.capture2e(
        env.merge("PHOTOS_DEPLOY_TEST_STALE_PROXY" => "1", "PHOTOS_DEPLOY_TEST_LEGACY_BACKEND" => "1"),
        "bash", root.join("scripts/deploy").to_s
      )

      assert_not status.success?, output
      calls = root.join("calls.log").read.lines.map(&:chomp)
      assert_includes output, "app_proxy did not route /up to web_green"
      assert_includes output, "the previous app_proxy upstream was restored"
      assert_equal "upstream photos_app { server web_blue:80; }\n", root.join("tmp/nginx/active_upstream.conf").read
      assert_not_includes calls, "compose stop web_blue"
      assert_not_includes calls, "compose up -d --no-deps worker --remove-orphans"
    end
  end

  test "deployment leaves the previous web container alive while nginx workers drain" do
    with_fake_deployment do |root, env|
      output, status = Open3.capture2e(env.merge("PHOTOS_DEPLOY_TEST_LONG_DRAIN" => "1"), "bash", root.join("scripts/deploy").to_s)

      assert status.success?, output
      calls = root.join("calls.log").read.lines.map(&:chomp)
      assert_includes output, "still draining; leaving web_blue running"
      assert_not_includes calls, "compose stop web_blue"
      assert_includes calls, "compose up -d --no-deps worker --remove-orphans"
    end
  end

  test "a live health response without a marker keeps the configured backend active" do
    with_fake_deployment do |root, env|
      output, status = Open3.capture2e(
        env.merge("PHOTOS_DEPLOY_TEST_LEGACY_BACKEND" => "1", "PHOTOS_DEPLOY_TEST_BLUE_UNHEALTHY" => "1"),
        "bash", root.join("scripts/deploy").to_s
      )

      assert status.success?, output
      assert_includes output, "active web: web_blue; next web: web_green"
      assert_includes root.join("calls.log").read, "compose up -d --no-deps --force-recreate web_green"
    end
  end

  test "deployment refuses to reuse a backend while a previous proxy generation drains" do
    with_fake_deployment do |root, env|
      output, status = Open3.capture2e(env.merge("PHOTOS_DEPLOY_TEST_EXISTING_DRAIN" => "1"), "bash", root.join("scripts/deploy").to_s)

      assert_not status.success?, output
      assert_includes output, "still draining connections from a previous release"
      assert_not_includes root.join("calls.log").read, "--force-recreate web_green"
      assert_not_includes root.join("calls.log").read, "compose build"
    end
  end

  test "deployment refuses to start when another deployment owns the lock" do
    with_fake_deployment do |root, env|
      output, status = Open3.capture2e(env.merge("PHOTOS_DEPLOY_TEST_LOCKED" => "1"), "bash", root.join("scripts/deploy").to_s)

      assert_not status.success?, output
      assert_includes output, "another deployment is running"
      assert_not root.join("calls.log").exist?
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
      %w[scripts bin storage tmp/nginx].each { |path| root.join(path).mkpath }
      FileUtils.cp(Rails.root.join("scripts/deploy"), root.join("scripts/deploy"))
      root.join(".env.production").write("PHOTOS_STORAGE_PATH=#{root.join('storage')}\nPHOTOS_HOST=photos.example.com\n")
      root.join(".env.postgres").write("")
      root.join("tmp/nginx/active_upstream.conf").write("upstream photos_app { server web_blue:80; }\n")
      root.join("serving").write("web_blue\n")
      root.join("bin/git").write("#!/usr/bin/env bash\nexit 0\n")
      root.join("bin/flock").write(<<~'BASH')
        #!/usr/bin/env bash
        [[ "${PHOTOS_DEPLOY_TEST_LOCKED:-0}" != 1 ]]
      BASH
      root.join("fake-bash-env").write("sleep() { SECONDS=$((SECONDS + $1)); }\n")
      root.join("bin/curl").write(<<~'BASH')
        #!/usr/bin/env bash
        set -eu
        marker=$(cat "$PHOTOS_DEPLOY_TEST_ROOT/serving")
        printf 'probe %s\n' "$marker" >> "$PHOTOS_DEPLOY_TEST_ROOT/calls.log"
        printf 'HTTP/1.1 200 OK\r\n'
        if [[ "$marker" != web_blue || "${PHOTOS_DEPLOY_TEST_LEGACY_BACKEND:-0}" != 1 ]]; then
          printf 'X-Photos-Backend: %s\r\n' "$marker"
        fi
        printf '\r\n'
      BASH
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
          elif [[ "$*" == *app_proxy-old ]]; then
            printf '%s\n' running
          elif [[ "$*" == *web_blue-old && "${PHOTOS_DEPLOY_TEST_BLUE_UNHEALTHY:-0}" == 1 ]]; then
            printf '%s\n' unhealthy
          else
            printf '%s\n' healthy
          fi
        elif [[ "$*" == "compose up -d --no-deps --force-recreate web_green" ]]; then
          touch "$PHOTOS_DEPLOY_TEST_ROOT/green-recreated"
        elif [[ "$*" == "compose exec -T app_proxy nginx -t" && "${PHOTOS_DEPLOY_TEST_INVALID_NGINX:-0}" == 1 ]]; then
          if grep -q web_green "$PHOTOS_DEPLOY_TEST_ROOT/tmp/nginx/active_upstream.conf"; then exit 1; fi
        elif [[ "$*" == "compose exec -T app_proxy nginx -s reload" ]]; then
          if grep -q web_green "$PHOTOS_DEPLOY_TEST_ROOT/tmp/nginx/active_upstream.conf"; then
            if [[ "${PHOTOS_DEPLOY_TEST_STALE_PROXY:-0}" != 1 ]]; then
              printf 'web_green\n' > "$PHOTOS_DEPLOY_TEST_ROOT/serving"
            fi
          else
            printf 'web_blue\n' > "$PHOTOS_DEPLOY_TEST_ROOT/serving"
          fi
        elif [[ "$*" == "compose exec -T app_proxy ps -o pid,args" ]]; then
          workers="11 12"
          if [[ "$(cat "$PHOTOS_DEPLOY_TEST_ROOT/serving")" == web_green ]]; then
            workers="21 22"
            if [[ "${PHOTOS_DEPLOY_TEST_LONG_DRAIN:-0}" == 1 ]]; then workers="12 $workers"; fi
          fi
          printf 'proxy workers %s\n' "$workers" >> "$PHOTOS_DEPLOY_TEST_ROOT/calls.log"
          printf 'PID COMMAND\n1 nginx: master process nginx\n'
          for pid in $workers; do printf '%s nginx: worker process\n' "$pid"; done
          if [[ "${PHOTOS_DEPLOY_TEST_EXISTING_DRAIN:-0}" == 1 ]]; then
            printf '10 nginx: worker process is shutting down\n'
          fi
        elif [[ "$1 $2" == "image prune" && "${PHOTOS_DEPLOY_TEST_PRUNE_FAILURE:-0}" == 1 ]]; then
          exit 1
        fi
      BASH
      root.join("bin").children.each { |path| path.chmod(0o755) }
      yield root, {
        "PATH" => "#{root.join('bin')}:/usr/bin:/bin",
        "BASH_ENV" => root.join("fake-bash-env").to_s,
        "PHOTOS_DEPLOY_TEST_ROOT" => root.to_s,
        "COMPOSE_PROFILES" => nil,
        "PHOTOS_DOCKER_CLEANUP" => nil,
        "PHOTOS_DEPLOY_TEST_BLUE_UNHEALTHY" => nil,
        "PHOTOS_DEPLOY_TEST_EXISTING_DRAIN" => nil,
        "PHOTOS_DEPLOY_TEST_INVALID_NGINX" => nil,
        "PHOTOS_DEPLOY_TEST_LEGACY_BACKEND" => nil,
        "PHOTOS_DEPLOY_TEST_LOCKED" => nil,
        "PHOTOS_DEPLOY_TEST_LONG_DRAIN" => nil,
        "PHOTOS_DEPLOY_TEST_PROJECT" => nil,
        "PHOTOS_DEPLOY_TEST_PRUNE_FAILURE" => nil,
        "PHOTOS_DEPLOY_TEST_STALE_PROXY" => nil,
        "PHOTOS_DEPLOY_TEST_WORKER_UNHEALTHY" => nil,
        "PHOTOS_UPDATE_INFRASTRUCTURE" => nil
      }
    end
  end
end
