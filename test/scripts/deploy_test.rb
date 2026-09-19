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
          elif [[ "$*" == *worker-old ]]; then
            printf '%s\n' running
          else
            printf '%s\n' healthy
          fi
        elif [[ "$*" == "compose up -d --no-deps --force-recreate web_green" ]]; then
          touch "$PHOTOS_DEPLOY_TEST_ROOT/green-recreated"
        elif [[ "$*" == "compose exec -T app_proxy nginx -t" && "${PHOTOS_DEPLOY_TEST_INVALID_NGINX:-0}" == 1 ]]; then
          exit 1
        fi
      BASH
      root.join("bin").children.each { |path| path.chmod(0o755) }
      yield root, {
        "PATH" => "#{root.join('bin')}:/usr/bin:/bin",
        "PHOTOS_DEPLOY_TEST_ROOT" => root.to_s,
        "COMPOSE_PROFILES" => nil
      }
    end
  end
end
