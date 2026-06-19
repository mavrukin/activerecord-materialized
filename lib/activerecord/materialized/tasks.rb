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
              Registry.refresh_all!
              puts "Refreshed #{Registry.all.size} materialized view(s)."
            end

            desc "Refresh stale materialized views"
            task refresh_stale: :environment do
              stale = Registry.all.select(&:stale?)
              stale.each(&:refresh!)
              puts "Refreshed #{stale.size} stale materialized view(s)."
            end
          end
        end
      end
    end
  end
end
