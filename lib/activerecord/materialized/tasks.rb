# typed: strict
# frozen_string_literal: true

module ActiveRecord
  module Materialized
    # Defines the `materialized:*` rake tasks (refresh_all, refresh_stale, rebuild, verify, warm_up).
    module Tasks
      extend T::Sig

      DEFINITIONS = T.let(
        {
          refresh_all: "Refresh all registered materialized views",
          refresh_stale: "Refresh stale materialized views",
          rebuild: "Rebuild (fully materialize) all registered materialized views",
          verify: "Verify materialized view cache tables match their source relations",
          audit: "Verify materialized view contents against their source relations (data drift)",
          warm_up: "Materialize each view's configured warm_up partitions"
        }.freeze,
        T::Hash[Symbol, String]
      )

      sig { void }
      def self.define!
        application = T.let(T.unsafe(::Rake.application), T.untyped)
        application.instance_eval do
          T.bind(self, T.untyped)

          namespace :materialized do
            DEFINITIONS.each do |task_name, description|
              desc description
              task(task_name => :environment) { Tasks.run!(task_name) }
            end
          end
        end
      end

      sig { params(task_name: Symbol).void }
      def self.run!(task_name)
        case task_name
        when :refresh_all then run_refresh_all!
        when :refresh_stale then run_refresh_stale!
        when :rebuild then run_rebuild_all!
        when :verify then run_verify!
        when :audit then run_audit!
        when :warm_up then run_warm_up_all!
        end
      end

      sig { void }
      def self.run_refresh_all!
        Registry.refresh_all!
        T.unsafe(Rails).logger.debug { "Refreshed #{Registry.all.size} materialized view(s)." }
      end

      sig { void }
      def self.run_refresh_stale!
        stale = Registry.all.select(&:stale?)
        stale.each(&:refresh!)
        T.unsafe(Rails).logger.debug { "Refreshed #{stale.size} stale materialized view(s)." }
      end

      sig { void }
      def self.run_rebuild_all!
        Registry.rebuild_all!
        T.unsafe(Rails).logger.debug { "Rebuilt #{Registry.all.size} materialized view(s)." }
      end

      sig { void }
      def self.run_verify!
        ActiveRecord::Materialized.verify_schema!
        T.unsafe(Rails).logger.debug { "Verified #{Registry.all.size} materialized view schema(s)." }
      end

      sig { void }
      def self.run_audit!
        ActiveRecord::Materialized.verify_data!
        T.unsafe(Rails).logger.debug { "Audited data for #{Registry.all.size} materialized view(s)." }
      end

      sig { void }
      def self.run_warm_up_all!
        Registry.warm_up_all!
        T.unsafe(Rails).logger.debug { "Warmed up #{Registry.all.size} materialized view(s)." }
      end
    end
  end
end
