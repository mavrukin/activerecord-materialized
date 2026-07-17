# frozen_string_literal: true

module ActiveRecord
  module Materialized
    # Routes work to a Rails multi-database role when the app has configured one: maintenance writes
    # to the primary, verification reads to a replica (the verify-on-replica / repair-on-primary
    # split). A nil role — the default — yields on the current connection, so single-database apps
    # and those relying on Rails' automatic role switching are unaffected.
    #
    # @api private
    module ConnectionRouting
      module_function

      def maintenance(&block)
        with_role(ActiveRecord::Materialized.configuration.maintenance_role, &block)
      end

      def verification(&block)
        with_role(ActiveRecord::Materialized.configuration.verification_role, &block)
      end

      def with_role(role, &block)
        return yield if role.nil?

        ActiveRecord::Base.connected_to(role: role, &block)
      end
    end
  end
end
