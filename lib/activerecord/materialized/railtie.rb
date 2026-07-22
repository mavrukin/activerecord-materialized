# frozen_string_literal: true

module ActiveRecord
  module Materialized
    # Rails integration: wires the gem's load hooks and rake tasks into a host application.
    class Railtie < ::Rails::Railtie
      rake_tasks do
        require_relative "tasks"
        Tasks.define!
      end

      # Load view classes on boot and on every dev reload so their depends_on commit callbacks are
      # installed even under Zeitwerk's lazy loading (config.eager_load = false). Without this, a view
      # whose constant nothing has referenced yet is dormant and writes to its dependencies don't
      # schedule maintenance. to_prepare runs after the autoloaders are set up (once in production,
      # on each reload in development), and ViewLoader.load! is idempotent.
      config.to_prepare do
        ActiveRecord::Materialized::ViewLoader.load!
      end

      # After the host's initializers have run (so config.refresh_dispatcher is final),
      # warn if the in-process refresher is active — it is single-process-only.
      config.after_initialize do
        ActiveRecord::Materialized.warn_if_in_process_dispatcher!
      end
    end
  end
end
