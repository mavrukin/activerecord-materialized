# typed: strict
# frozen_string_literal: true

module ActiveRecord
  module Materialized
    # Rails integration: wires the gem's load hooks and rake tasks into a host application.
    class Railtie < ::Rails::Railtie
      extend T::Sig

      rake_tasks do
        require_relative "tasks"
        Tasks.define!
      end
    end
  end
end
