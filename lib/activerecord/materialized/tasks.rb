# frozen_string_literal: true

module ActiveRecord
  module Materialized
    # Defines the `materialized:*` rake tasks (refresh_all, refresh_stale, rebuild, verify, warm_up).
    module Tasks
      DEFINITIONS = {
        refresh_all: "Refresh all registered materialized views",
        refresh_stale: "Refresh stale materialized views",
        rebuild: "Rebuild (fully materialize) all registered materialized views",
        verify: "Verify materialized view cache tables match their source relations",
        audit: "Verify materialized view contents against their source relations (data drift)",
        reconcile: "Reconcile stale materialized views: verify contents and repair drift (scoped)",
        warm_up: "Materialize each view's configured warm_up partitions"
      }.freeze

      def self.define!
        application = ::Rake.application
        application.instance_eval do
          namespace :materialized do
            DEFINITIONS.each do |task_name, description|
              desc description
              task(task_name => :environment) { Tasks.run!(task_name) }
            end
          end
        end
      end

      # Each task name maps by convention to its `run_<task_name>!` module method.
      def self.run!(task_name)
        public_send(:"run_#{task_name}!")
      end

      def self.run_refresh_all!
        Registry.refresh_all!
        Rails.logger.debug { "Refreshed #{Registry.all.size} materialized view(s)." }
      end

      def self.run_refresh_stale!
        stale = Registry.all.select(&:stale?)
        stale.each(&:refresh!)
        Rails.logger.debug { "Refreshed #{stale.size} stale materialized view(s)." }
      end

      def self.run_rebuild!
        Registry.rebuild_all!
        Rails.logger.debug { "Rebuilt #{Registry.all.size} materialized view(s)." }
      end

      def self.run_verify!
        ActiveRecord::Materialized.verify_schema!
        Rails.logger.debug { "Verified #{Registry.all.size} materialized view schema(s)." }
      end

      def self.run_audit!
        ActiveRecord::Materialized.verify_data!
        Rails.logger.debug { "Audited data for #{Registry.all.size} materialized view(s)." }
      end

      def self.run_reconcile!
        results = ActiveRecord::Materialized.reconcile_stale!
        repaired = results.sum(&:repaired_partition_count)
        failed = results.count(&:failed?)
        Rails.logger.debug do
          "Reconciled #{results.size} stale view(s); repaired #{repaired} partition(s); #{failed} failed."
        end
      end

      def self.run_warm_up!
        Registry.warm_up_all!
        Rails.logger.debug { "Warmed up #{Registry.all.size} materialized view(s)." }
      end
    end
  end
end
