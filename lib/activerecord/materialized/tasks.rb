# typed: strict
# frozen_string_literal: true

module ActiveRecord
  module Materialized
    module Tasks
      extend T::Sig

      sig { void }
      def self.define!
        application = T.let(T.unsafe(::Rake.application), T.untyped)
        T.unsafe(application).instance_eval do
          T.bind(self, T.untyped)

          namespace :materialized do
            desc "Refresh all registered materialized views"
            task refresh_all: :environment do
              ActiveRecord::Materialized::Tasks.run_refresh_all!
            end

            desc "Refresh stale materialized views"
            task refresh_stale: :environment do
              ActiveRecord::Materialized::Tasks.run_refresh_stale!
            end
          end
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
    end
  end
end
