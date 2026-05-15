class BotProbeFilter
  CONTENT_TYPE = "text/plain; charset=utf-8"
  CACHE_PREFIX = "bot_probe_filter".freeze
  WINDOW_SECONDS = 300
  LIMIT = 8

  SUSPICIOUS_FILENAMES = /
    \A
    (?:
      api\.sql|
      [a-z0-9_-]{2,64}
      \.
      (?:
        7z|bak|bz2|gz|rar|sql|tar|tar\.(?:bz2|gz|xz|zst)|tgz|xz|zip|zst|
        sql\.(?:bz2|gz|xz|zip|zst)
      )
    )
    \z
  /ix

  SUSPICIOUS_PATHS = %r{
    \A
    (?:
      \.env(?:\..*)?|
      \.git(?:/.*)?|
      \.svn(?:/.*)?|
      \.hg(?:/.*)?|
      wp-(?:admin|content|includes)(?:/.*)?|
      wordpress(?:/.*)?|
      phpmyadmin(?:/.*)?|
      pma(?:/.*)?|
      vendor(?:/.*)?|
      storage(?:/.*)?|
      config(?:/.*)?|
      backups?(?:/.*)?
    )
    \z
  }ix

  def initialize(app)
    @app = app
  end

  def call(env)
    request = Rack::Request.new(env)
    return @app.call(env) unless suspicious?(request.path_info)

    return too_many_requests if record_probe(remote_address(env)) > LIMIT

    not_found
  end

  private

  def suspicious?(path)
    clean_path = path.to_s.delete_prefix("/").downcase
    return false if clean_path.blank?

    (!clean_path.include?("/") && clean_path.match?(SUSPICIOUS_FILENAMES)) ||
      clean_path.match?(SUSPICIOUS_PATHS)
  end

  def remote_address(env)
    env["action_dispatch.remote_ip"].presence ||
      env["HTTP_X_FORWARDED_FOR"].to_s.split(",").first.presence ||
      env["REMOTE_ADDR"].presence ||
      "unknown"
  end

  def record_probe(remote_address)
    key = "#{CACHE_PREFIX}:#{remote_address}"
    count = Rails.cache.read(key).to_i + 1
    Rails.cache.write(key, count, expires_in: WINDOW_SECONDS)
    count
  rescue StandardError
    1
  end

  def not_found
    [ 404, headers, [ "Not found\n" ] ]
  end

  def too_many_requests
    [
      429,
      headers.merge("Retry-After" => WINDOW_SECONDS.to_s),
      [ "Too many requests\n" ]
    ]
  end

  def headers
    {
      "Content-Type" => CONTENT_TYPE,
      "Cache-Control" => "no-store",
      "X-Robots-Tag" => "noindex, nofollow"
    }
  end
end
