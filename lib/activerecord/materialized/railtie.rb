# typed: strict
# frozen_string_literal: true

module ActiveRecord
  module Materialized
    class Railtie < ::Rails::Railtie
      extend T::Sig

      rake_tasks do
        require_relative "tasks"
        Tasks.define!
      end

      initializer "activerecord_materialized.install" do
        ::ActiveSupport.on_load(:active_record) do
          InstallHooks.install!
        end
      end
    end
  end
end
