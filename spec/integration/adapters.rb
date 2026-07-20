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
#   ARM_ONLY=sqlite,mysql                      restrict to named adapters; those adapters
#                                              then MUST be reachable or the run fails
module IntegrationAdapters
  KEYS = %i[sqlite mysql postgres].freeze

  # adapter name + env prefix + default port used when only some parts are given.
  SETTINGS = {
    mysql: { adapter: "trilogy", prefix: "ARM_MYSQL", port: 3306 },
    postgres: { adapter: "postgresql", prefix: "ARM_PG", port: 5432 }
  }.freeze

  LABELS = { sqlite: "SQLite", mysql: "MySQL", postgres: "PostgreSQL" }.freeze

  # Real change-log capture strategy per adapter (#80): decode the DB's own change log rather than
  # synthesizing the CDC descriptor at the write site. See spec/integration/support/cdc_capture.rb.
  CAPTURE = { sqlite: :none, mysql: :binlog, postgres: :logical_slot }.freeze

  # Raised when an ARM_* value can't be parsed into a connection config. Caught in
  # `profile`, so one malformed adapter is reported unavailable rather than
  # crashing the whole suite at spec-collection time.
  class ConfigError < StandardError; end

  # One database under test. A `required` adapter (named explicitly via ARM_ONLY)
  # must be reachable — the spec fails, not skips, when it is not.
  AdapterProfile = Struct.new(:key, :label, :connection_config, :required, :config_error, :capture,
                              keyword_init: true) do
    def available? = unavailable_reason.nil?

    def required? = required

    # nil when reachable; otherwise a human reason (bad config, missing config,
    # dead server, missing client gem). Memoized so the probe runs at most once.
    def unavailable_reason
      return @unavailable_reason if defined?(@unavailable_reason)

      @unavailable_reason = config_error || compute_unavailable_reason
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

  def profile(key, env = ENV, required: false)
    build_profile(key, connection_config(key, env), required: required)
  rescue ConfigError => e
    build_profile(key, nil, required: required, config_error: e.message)
  end

  # ARM_ONLY-filtered profiles, in KEYS order. Not availability-probed (safe to
  # call at spec-collection time); callers check #available? inside a hook. An
  # ARM_ONLY token outside KEYS raises, so a typo can't yield a vacuous pass.
  def candidates(env = ENV)
    only = env["ARM_ONLY"].to_s.split(",").map(&:strip).reject(&:empty?).map(&:to_sym)
    reject_unknown!(only)
    keys = only.empty? ? KEYS : KEYS.select { |key| only.include?(key) }
    keys.map { |key| profile(key, env, required: only.any?) }
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

  def reject_unknown!(only)
    unknown = only - KEYS
    return if unknown.empty?

    raise ConfigError, "unknown ARM_ONLY adapter(s): #{unknown.join(', ')} (known: #{KEYS.join(', ')})"
  end
  private_class_method :reject_unknown!

  def build_profile(key, config, required:, config_error: nil)
    AdapterProfile.new(
      key: key, label: LABELS.fetch(key), connection_config: config, required: required,
      config_error: config_error, capture: CAPTURE.fetch(key)
    )
  end
  private_class_method :build_profile

  def from_url(settings, url)
    return nil if url.blank?

    uri = URI.parse(url)
    present(
      adapter: settings[:adapter], host: uri.host, port: uri.port || settings[:port],
      username: uri.user, password: uri.password, database: uri.path.delete_prefix("/")
    )
  rescue URI::InvalidURIError => e
    raise ConfigError, "invalid #{settings[:prefix]}_URL: #{e.message}"
  end
  private_class_method :from_url

  def from_parts(settings, env)
    prefix = settings[:prefix]
    host = env["#{prefix}_HOST"]
    return nil if host.blank?

    present(
      adapter: settings[:adapter], host: host, port: port_from(env["#{prefix}_PORT"], settings[:port]),
      username: env["#{prefix}_USER"], password: env["#{prefix}_PASSWORD"], database: env["#{prefix}_DATABASE"]
    )
  end
  private_class_method :from_parts

  # A blank port falls back to the default; a non-numeric one is a real misconfig.
  def port_from(raw, default)
    return default if raw.blank?

    Integer(raw)
  rescue ArgumentError
    raise ConfigError, "non-numeric port #{raw.inspect}"
  end
  private_class_method :port_from

  # Drop nil and blank values so a missing env part never becomes an empty-string
  # host/database that yields an opaque connection error.
  def present(config)
    config.reject { |_, value| value.nil? || value.to_s.empty? }
  end
  private_class_method :present
end
