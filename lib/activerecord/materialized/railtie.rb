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
    end
  end
end
