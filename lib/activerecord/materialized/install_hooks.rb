# typed: strict
# frozen_string_literal: true

module ActiveRecord
  module Materialized
    module InstallHooks
      extend T::Sig

      module_function

      sig { void }
      def install!
        return if @installed

        ChangeSubscriber.install!
        @installed = T.let(true, T.nilable(T::Boolean))
      end
    end
  end
end
