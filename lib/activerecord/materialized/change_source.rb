# typed: strict
# frozen_string_literal: true

module ActiveRecord
  module Materialized
    # The change sources a view can declare. `:callbacks` (the default) installs
    # the built-in ActiveRecord commit-callback tracker on `depends_on` models;
    # `:none` installs no callbacks and expects changes through the public
    # ingestion API from an external adapter.
    module ChangeSource
      extend T::Sig

      CALLBACKS = :callbacks
      NONE = :none
      NAMES = T.let([CALLBACKS, NONE].freeze, T::Array[Symbol])

      # Validates and normalizes a change-source name, raising on an unknown one
      # so a typo fails loudly at definition/configuration time instead of
      # silently disabling all maintenance for the view.
      sig { params(source: T.any(Symbol, String)).returns(Symbol) }
      def self.cast(source)
        name = source.to_sym
        return name if NAMES.include?(name)

        raise ArgumentError, "Unknown change source #{source.inspect} (expected one of #{NAMES.inspect})"
      end
    end
  end
end
