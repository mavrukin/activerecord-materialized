# frozen_string_literal: true

require "uri"

# Describes each database under integration test (#70): how to connect and
# whether it is reachable right now. Adding a new database type is one new entry
# in KEYS + SETTINGS (plus its client gem in the Gemfile :integration group) —
# the specs never change.
#
# Connection details come from the environment so CI and local Docker Compose can
# point the same matrix at different servers:
#   ARM_<DB>_URL                               e.g. ARM_PG_URL=postgres://u:p@host:5432/db
#   ARM_<DB>_HOST/PORT/USER/PASSWORD/DATABASE  discrete parts (URL wins if both are set)
#   ARM_ONLY=sqlite,mysql                      restrict the matrix to named adapters
module IntegrationAdapters
  KEYS = %i[sqlite mysql postgres].freeze

  # adapter name + env prefix + default port used when only some parts are given.
  SETTINGS = {
    mysql: { adapter: "trilogy", prefix: "ARM_MYSQL", port: 3306 },
    postgres: { adapter: "postgresql", prefix: "ARM_PG", port: 5432 }
  }.freeze

  LABELS = { sqlite: "SQLite", mysql: "MySQL", postgres: "PostgreSQL" }.freeze

  # One database under test.
  AdapterProfile = Struct.new(:key, :label, :connection_config, keyword_init: true) do
    def available?
      unavailable_reason.nil?
    end

    # nil when reachable; otherwise a human reason (missing config, dead server,
    # missing client gem). Memoized so the connection probe runs at most once.
    def unavailable_reason
      return @unavailable_reason if defined?(@unavailable_reason)

      @unavailable_reason = compute_unavailable_reason
    end

    private

    def compute_unavailable_reason
      return nil if key == :sqlite
      return "no connection config (set #{SETTINGS.fetch(key)[:prefix]}_URL or _HOST)" if connection_config.nil?

      probe
    end

    # Open a real connection and round-trip SELECT 1; any failure (missing client
    # gem, server down, auth) marks the adapter unavailable with the message
    # rather than erroring the suite.
    def probe
      ActiveRecord::Base.establish_connection(connection_config)
      ActiveRecord::Base.connection.execute("SELECT 1")
      nil
    rescue StandardError, LoadError => e
      "#{e.class}: #{e.message.lines.first&.strip}"
    end
  end

  module_function

  def profile(key, env = ENV)
    AdapterProfile.new(key: key, label: LABELS.fetch(key), connection_config: connection_config(key, env))
  end

  # ARM_ONLY-filtered profiles, in KEYS order. Not availability-probed (safe to
  # call at spec-collection time); callers check #available? inside a hook.
  def candidates(env = ENV)
    only = env["ARM_ONLY"].to_s.split(",").map { |name| name.strip.to_sym }
    keys = only.empty? ? KEYS : KEYS & only
    keys.map { |key| profile(key, env) }
  end

  # Available profiles only (probes each) — for callers that just want to run.
  def all(env = ENV)
    candidates(env).select(&:available?)
  end

  def connection_config(key, env = ENV)
    return { adapter: "sqlite3", database: ":memory:" } if key == :sqlite

    settings = SETTINGS.fetch(key)
    from_url(settings, env["#{settings[:prefix]}_URL"]) || from_parts(settings, env)
  end

  def from_url(settings, url)
    return nil if url.blank?

    uri = URI.parse(url)
    {
      adapter: settings[:adapter], host: uri.host, port: uri.port || settings[:port],
      username: uri.user, password: uri.password, database: uri.path.delete_prefix("/")
    }.compact
  end
  private_class_method :from_url

  def from_parts(settings, env)
    prefix = settings[:prefix]
    host = env["#{prefix}_HOST"]
    return nil if host.blank?

    {
      adapter: settings[:adapter], host: host, port: Integer(env["#{prefix}_PORT"] || settings[:port]),
      username: env["#{prefix}_USER"], password: env["#{prefix}_PASSWORD"], database: env["#{prefix}_DATABASE"]
    }.compact
  end
  private_class_method :from_parts
end
