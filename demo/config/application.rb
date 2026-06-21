# frozen_string_literal: true

require_relative "boot"

# Pull in only the framework pieces this demo needs — no asset pipeline,
# mailer, jobs, or storage.
require "active_record/railtie"
require "action_controller/railtie"

Bundler.require(*Rails.groups)

module Demo
  class Application < Rails::Application
    config.load_defaults 8.0

    # A demo runs one process against a prebuilt SQLite database, so eager
    # loading and host checks only get in the way.
    config.eager_load = false
    config.hosts.clear

    config.time_zone = "UTC"
    config.active_record.default_timezone = :utc

    # Demo-only secret; never reuse this in a real application.
    config.secret_key_base = "activerecord-materialized-demo-secret-key-base"

    # The scenario registry / query runner live in demo/lib and are loaded
    # explicitly (see config/initializers/demo.rb) rather than autoloaded, so
    # they stay out of Zeitwerk's way and load alongside the benchmark models.
  end
end
