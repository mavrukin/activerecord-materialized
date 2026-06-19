# frozen_string_literal: true

module ActiveRecord
  module Materialized
    module InstallHooks
      module_function

      def install!
        return if @installed

        ChangeSubscriber.install!
        @installed = true
      end
    end
  end
end
