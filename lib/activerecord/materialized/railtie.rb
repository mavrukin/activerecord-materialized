# frozen_string_literal: true

module ActiveRecord
  module Materialized
    # Rails integration: wires the gem's load hooks and rake tasks into a host application.
    class Railtie < ::Rails::Railtie
      rake_tasks do
        require_relative "tasks"
        Tasks.define!
      end

      # After the host's initializers have run (so config.refresh_dispatcher is final),
      # warn if the in-process refresher is active — it is single-process-only.
      config.after_initialize do
        ActiveRecord::Materialized.warn_if_in_process_dispatcher!
      end
    end
  end
end
